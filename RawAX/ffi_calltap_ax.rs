// CallTap, 2026. SPDX-License-Identifier: Apache-2.0
use std::{ffi::c_void,ptr::null_mut,time::Duration};
use crate::{IdeviceFfiError,ffi_err,run_sync_local,core_device_proxy::AdapterHandle,rsd::RsdHandshakeHandle};
use idevice::IdeviceError;

/// Current-call/lock checks and one-shot action reservations. Actions: 0 check,
/// 1 reserve More, 2 reserve recording start. Called on the invoking worker.
pub type CallTapAXGuard = Option<unsafe extern "C" fn(*mut c_void,u32)->bool>;

/// Inspects native call UI; may open More once and then submit recording start
/// once in the same connection after bounded menu-stabilization reads.
/// Caller owns adapter/handshake, must keep them on their original thread, and
/// must not reuse either until this bounded call returns. No XCTest is started.
///
/// # Safety
/// All handles/context/outcome pointers must remain valid until return. The
/// callback must be thread-safe and must not reenter this FFI runtime.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn calltap_ax_inspect(
    adapter:*mut AdapterHandle, handshake:*mut RsdHandshakeHandle,
    may_open_more:bool, callback:CallTapAXGuard, context:*mut c_void,
    outcome:*mut u32,
)->*mut IdeviceFfiError {
    if adapter.is_null()||handshake.is_null()||outcome.is_null()||callback.is_none(){return ffi_err!(IdeviceError::FfiInvalidArg);}
    unsafe{*outcome=0;}
    let guard=callback.unwrap();let context=context as usize;
    let result=run_sync_local(async move {
        let operation=idevice::dvt::calltap_ax::inspect(unsafe{&mut (*adapter).0},unsafe{&mut (*handshake).0},may_open_more,move|action|unsafe{guard(context as *mut c_void,action)});
        tokio::time::timeout(Duration::from_secs(22),operation).await.map_err(|_|IdeviceError::UnexpectedResponse("CallTap AX: inspection timed out; a reserved action must not be replayed".into()))?
    });
    match result {Ok(value)=>{unsafe{*outcome=value;}null_mut()},Err(error)=>ffi_err!(error)}
}
