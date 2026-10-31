// CallTap, 2026. SPDX-License-Identifier: Apache-2.0
// Uses the pinned idevice (MIT) public Remote Pairing / CDTunnel transport.
// This connector never invokes pair-setup, a PIN prompt, or a VPN API.
use std::{cell::Cell, ffi::{CStr, c_char}, net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr}, ptr::null_mut, time::Duration};
use idevice::{IdeviceError, remote_pairing::{RemotePairingClient, RpPairingSocket, connect_tls_psk_tunnel_native}, rsd::RsdHandshake};
use crate::{IdeviceFfiError, ffi_err, run_sync_local, core_device_proxy::AdapterHandle, rp_pairing_file::RpPairingFileHandle, rsd::RsdHandshakeHandle};

const DIRECT_PORT: u16 = 49152;

fn direct_address(host: &str) -> Option<SocketAddr> {
    let ip = match host {
        "127.0.0.1" => IpAddr::V4(Ipv4Addr::LOCALHOST),
        "::1" => IpAddr::V6(Ipv6Addr::LOCALHOST),
        _ => return None,
    };
    Some(SocketAddr::new(ip, DIRECT_PORT))
}

// Fixed stage numbers are the only connection diagnostics exported to Swift.
// Never include underlying errors: they may contain pairing or device data.
fn refused(stage: u32) -> IdeviceError {
    IdeviceError::UnexpectedResponse(format!("CallTap Direct: stage {stage} refused"))
}
fn timed_out(stage: u32) -> IdeviceError {
    IdeviceError::UnexpectedResponse(format!("CallTap Direct: stage {stage} timed out"))
}

/// Creates an authenticated direct loopback connection, without pair-setup.
/// Host must be exactly `127.0.0.1` or `::1`; no DNS, LAN or VPN address is used.
/// Stages: 1 initial TCP, 2 RP handshake, 3 stored-pair verification,
/// 4 dynamic listener, 5 listener TCP, 6 TLS/CDTunnel, 7 tunnel parameters,
/// 8 RSD stream, 9 RSD discovery. The full candidate takes at most 10 seconds.
///
/// # Safety
/// Host must be a valid NUL-terminated string. Pairing must be a valid borrowed
/// handle. Output pointers must be valid, writable, distinct locations, with no
/// existing live handles. On failure both outputs are NULL. On success caller
/// owns both handles and must probe/use/free them on this same original thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn calltap_direct_connect(
    host: *const c_char,
    pairing: *mut RpPairingFileHandle,
    out_adapter: *mut *mut AdapterHandle,
    out_handshake: *mut *mut RsdHandshakeHandle,
) -> *mut IdeviceFfiError {
    // Do not leave stale handles behind even for rejected arguments.
    if !out_adapter.is_null() { unsafe { *out_adapter = null_mut(); } }
    if !out_handshake.is_null() { unsafe { *out_handshake = null_mut(); } }
    if host.is_null() || pairing.is_null() || out_adapter.is_null() || out_handshake.is_null()
        || out_adapter.cast::<()>() == out_handshake.cast::<()>() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let address = match unsafe { CStr::from_ptr(host) }.to_str().ok().and_then(direct_address) {
        Some(address) => address,
        None => return ffi_err!(IdeviceError::FfiInvalidArg),
    };
    idevice::dvt::calltap_ax::initialize_crypto();
    let stage = Cell::new(1u32);
    let result = run_sync_local(async {
        let operation = async {
            let stream = tokio::time::timeout(Duration::from_secs(2), tokio::net::TcpStream::connect(address))
                .await.map_err(|_| timed_out(1))?.map_err(|_| refused(1))?;
            let mut rpc = RemotePairingClient::new(RpPairingSocket::new(stream), "CallTap Direct");
            stage.set(2);
            rpc.attempt_pair_verify().await.map_err(|_| refused(2))?;
            stage.set(3);
            // Deliberately avoid rpc.connect(): it can fall back to pair-setup.
            rpc.validate_pairing(unsafe { &mut (*pairing).0 }).await.map_err(|_| refused(3))?;
            stage.set(4);
            let port = rpc.create_tcp_listener().await.map_err(|_| refused(4))?;
            if port == 0 { return Err(refused(4)); }
            let mut listener_address = address;
            listener_address.set_port(port);
            stage.set(5);
            let stream = tokio::time::timeout(Duration::from_secs(2), tokio::net::TcpStream::connect(listener_address))
                .await.map_err(|_| timed_out(5))?.map_err(|_| refused(5))?;
            stage.set(6);
            let tunnel = connect_tls_psk_tunnel_native(stream, rpc.encryption_key())
                .await.map_err(|_| refused(6))?;
            stage.set(7);
            let client_ip: IpAddr = tunnel.info.client_address.parse().map_err(|_| refused(7))?;
            let server_ip: IpAddr = tunnel.info.server_address.parse().map_err(|_| refused(7))?;
            let mtu = tunnel.info.mtu as usize;
            let rsd_port = tunnel.info.server_rsd_port;
            if !(576..=65_535).contains(&mtu) || rsd_port == 0 { return Err(refused(7)); }
            let mut adapter = idevice::tcp::adapter::Adapter::new(Box::new(tunnel.into_inner()), client_ip, server_ip);
            adapter.set_mss(mtu.saturating_sub(60));
            let mut adapter = adapter.to_async_handle();
            stage.set(8);
            let rsd_stream = adapter.connect(rsd_port).await.map_err(|_| refused(8))?;
            stage.set(9);
            let handshake = RsdHandshake::new(rsd_stream).await.map_err(|_| refused(9))?;
            Ok::<_, IdeviceError>((adapter, handshake))
        };
        tokio::time::timeout(Duration::from_secs(10), operation).await
            .map_err(|_| timed_out(stage.get()))?
    });
    match result {
        Ok((adapter, handshake)) => {
            unsafe {
                *out_adapter = Box::into_raw(Box::new(AdapterHandle(adapter)));
                *out_handshake = Box::into_raw(Box::new(RsdHandshakeHandle(handshake)));
            }
            null_mut()
        }
        Err(error) => ffi_err!(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exact_numeric_loopbacks_have_fixed_pairing_port() {
        assert_eq!(direct_address("127.0.0.1"), Some(SocketAddr::from(([127, 0, 0, 1], 49152))));
        assert_eq!(direct_address("::1"), Some(SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), 49152)));
    }
    #[test]
    fn vpn_lan_dns_and_noncanonical_input_are_rejected() {
        for host in ["10.7.0.1", "192.168.0.1", "localhost", "127.0.0.2", "[::1]", "::ffff:127.0.0.1", "127.0.0.1:49152", " 127.0.0.1", "::1\n", ""] {
            assert!(direct_address(host).is_none());
        }
    }
    #[test]
    fn null_input_clears_outputs_without_opening_a_socket() {
        let mut adapter = std::ptr::dangling_mut::<AdapterHandle>();
        let mut handshake = std::ptr::dangling_mut::<RsdHandshakeHandle>();
        let error = unsafe { calltap_direct_connect(null_mut(), null_mut(), &mut adapter, &mut handshake) };
        assert!(!error.is_null());
        assert!(adapter.is_null() && handshake.is_null());
        unsafe { crate::idevice_error_free(error); }
    }
}
