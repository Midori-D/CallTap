// CallTap, 2026. SPDX-License-Identifier: Apache-2.0
// AX wire format adapted from ipb (MIT); see RawAX/IPB-LICENSE.
// This module is compiled inside the pinned idevice crate to reuse its DTX transport.
use std::{collections::{HashMap, HashSet}, io::Cursor, time::Duration};
use plist::{Dictionary, Uid, Value};
use tokio::sync::mpsc;
use crate::{IdeviceError, ReadWrite, RsdService, provider::RsdProvider, rsd::RsdHandshake};
use super::{message::{AuxValue, Message}, remote_server::{RemoteServerClient, OwnedChannel, IncomingHandlerOutcome}};

const AX_SERVICE: &str = "com.apple.accessibility.axAuditDaemon.remoteAXService";
const ELEMENT: &str = "UIAccessibilitySnapshotKeyElement";
const CHILDREN: &str = "UIAccessibilitySnapshotKeyChildren";
const ATTRS: &str = "UIAccessibilitySnapshotKeyAttributes";
const CHILD_COUNT: &str = "UIAccessibilitySnapshotKeyChildrenCount";
const LIMIT: usize = 20 * 1024 * 1024;
const TRAIT_BUTTON: u64 = 1;
const TRAIT_SELECTED: u64 = 8;
type Token = Value;

fn err(message: &str) -> IdeviceError { IdeviceError::UnexpectedResponse(format!("CallTap AX: {message}")) }
fn dict(value: &Value) -> Result<&Dictionary, IdeviceError> { value.as_dictionary().ok_or_else(|| err("expected dictionary")) }
fn field<'a>(value: &'a Value, key: &str) -> Result<&'a Value, IdeviceError> { dict(value)?.get(key).ok_or_else(|| err("missing required field")) }
fn number(value: &Value) -> Option<u64> { value.as_unsigned_integer().or_else(|| value.as_signed_integer().and_then(|v| u64::try_from(v).ok())) }
fn yes(value: Option<&Value>) -> bool { matches!(value, Some(Value::Boolean(true))) || value.and_then(number) == Some(1) }
fn nil() -> Value { Value::String("$null".into()) }
fn map(entries: Vec<(&str, Value)>) -> Value { Value::Dictionary(entries.into_iter().map(|(k,v)| (k.to_owned(),v)).collect()) }
fn key(token: &Token) -> Result<(u64,u64), IdeviceError> {
    let pid = number(field(token,"pid")?).ok_or_else(|| err("invalid process identity"))?;
    let id = number(field(token,"objectID")?).ok_or_else(|| err("invalid element identity"))?;
    if pid == 0 || id == 0 { return Err(err("empty native identity")); }
    Ok((pid,id))
}

// Bounded keyed-archive decoder. It never instantiates private Objective-C classes.
fn decode(data: &[u8]) -> Result<Value, IdeviceError> {
    if data.len() > LIMIT { return Err(err("archive size limit")); }
    let archive = Value::from_reader(Cursor::new(data)).map_err(|_| err("invalid archive"))?;
    let objects = field(&archive,"$objects")?.as_array().ok_or_else(|| err("invalid object table"))?;
    if objects.len() > 50_000 { return Err(err("object count limit")); }
    let root = field(field(&archive,"$top")?,"root")?;
    fn visit(v: &Value, objects: &[Value], visiting: &mut HashSet<usize>, depth: usize, budget: &mut usize) -> Result<Value,IdeviceError> {
        if depth > 128 || *budget == 0 { return Err(err("archive work limit")); }
        *budget -= 1;
        match v {
            Value::Uid(uid) => {
                let index = usize::try_from(uid.get()).map_err(|_| err("invalid UID"))?;
                if index == 0 { return Ok(nil()); }
                if !visiting.insert(index) { return Err(err("cyclic archive")); }
                let result = visit(objects.get(index).ok_or_else(|| err("UID outside object table"))?, objects, visiting, depth+1, budget);
                visiting.remove(&index); result
            }
            Value::Array(values) => Ok(Value::Array(values.iter().map(|v| visit(v,objects,visiting,depth+1,budget)).collect::<Result<_,_>>()?)),
            Value::Dictionary(values) => {
                let mut decoded = Dictionary::new();
                for (k,v) in values { if k != "$class" { decoded.insert(k.clone(),visit(v,objects,visiting,depth+1,budget)?); } }
                if let (Some(Value::Array(keys)),Some(Value::Array(vals))) = (decoded.get("NS.keys"),decoded.get("NS.objects")) {
                    if keys.len()!=vals.len() { return Err(err("dictionary size mismatch")); }
                    let mut result = Dictionary::new();
                    for (k,v) in keys.iter().zip(vals) {
                        let name = k.as_string().map(str::to_owned).or_else(|| number(k).map(|n|n.to_string())).ok_or_else(||err("unsupported dictionary key"))?;
                        result.insert(name,v.clone());
                    }
                    return Ok(Value::Dictionary(result));
                }
                if let Some(Value::Array(items)) = decoded.get("NS.objects") { return Ok(Value::Array(items.clone())); }
                for name in ["NSString","NS.string"] { if let Some(Value::String(s))=decoded.get(name) { return Ok(Value::String(s.clone())); } }
                if let Some(Value::Data(bytes))=decoded.get("NS.data") { return Ok(Value::Data(bytes.clone())); }
                if let Some(Value::String(rect))=decoded.get("NS.rectval") {
                    let values: Vec<f64> = rect.split(|c:char| c=='{' || c=='}' || c==',' || c.is_whitespace()).filter(|s|!s.is_empty()).map(str::parse).collect::<Result<_,_>>().map_err(|_|err("invalid rectangle"))?;
                    if values.len()!=4 { return Err(err("invalid rectangle")); }
                    if !values.iter().all(|n|n.is_finite()) { return Ok(map(vec![("unavailable",Value::String("CGRectNull".into()))])); }
                    return Ok(Value::Dictionary(["x","y","width","height"].into_iter().zip(values).map(|(k,v)|(k.to_owned(),Value::Real(v))).collect()));
                }
                Ok(Value::Dictionary(decoded))
            }
            _ => Ok(v.clone()),
        }
    }
    visit(root,objects,&mut HashSet::new(),0,&mut 300_000)
}

struct Archive { objects: Vec<Value>, classes: HashMap<String,Value> }
impl Archive {
    fn new()->Self { Self { objects:vec![nil()], classes:HashMap::new() } }
    fn add(&mut self,v:Value)->Value { self.objects.push(v); Value::Uid(Uid::new((self.objects.len()-1) as u64)) }
    fn class(&mut self,name:&str)->Value {
        if let Some(id)=self.classes.get(name) { return id.clone(); }
        let id=self.add(map(vec![("$classname",Value::String(name.into())),("$classes",Value::Array(vec![Value::String(name.into()),Value::String("NSObject".into())]))]));
        self.classes.insert(name.into(),id.clone()); id
    }
    fn object(&mut self,v:&Value)->Value {
        if *v == nil() { return Value::Uid(Uid::new(0)); }
        match v {
            Value::Dictionary(values) => {
                let keys=values.keys().map(|k|self.object(&Value::String(k.clone()))).collect();
                let vals=values.values().map(|v|self.object(v)).collect(); let class=self.class("NSDictionary");
                self.add(map(vec![("NS.keys",Value::Array(keys)),("NS.objects",Value::Array(vals)),("$class",class)]))
            }
            Value::Array(values) => { let items=values.iter().map(|v|self.object(v)).collect();let class=self.class("NSArray");self.add(map(vec![("NS.objects",Value::Array(items)),("$class",class)])) }
            _ => self.add(v.clone()),
        }
    }
    fn token(&mut self,v:&Value)->Result<Value,IdeviceError> {
        let values=dict(v)?; let mut result=Dictionary::new();
        for name in ["rawElementData","bridgeDelegateToken","objectID"] { result.insert(name.into(),self.object(values.get(name).unwrap_or(&nil()))); }
        for name in ["pid","isApplicationElement","didPopuldateAppInfo"] { result.insert(name.into(),values.get(name).cloned().unwrap_or_else(||if name=="pid" {Value::Integer(0.into())}else{Value::Boolean(false)})); }
        result.insert("$class".into(),self.class("AXPTranslationObject")); Ok(self.add(Value::Dictionary(result)))
    }
    fn finish(self,root:Value)->Result<Vec<u8>,IdeviceError> {
        let value=map(vec![("$version",Value::Integer(100000.into())),("$archiver",Value::String("NSKeyedArchiver".into())),("$top",map(vec![("root",root)])),("$objects",Value::Array(self.objects))]);
        let mut output=Vec::new();value.to_writer_binary(&mut output).map_err(|_|err("cannot encode archive"))?;Ok(output)
    }
}

fn request(kind:u64, params:Option<Value>, token:Option<&Token>, action:u64)->Result<Vec<u8>,IdeviceError> {
    let mut a=Archive::new();
    let (params,token)=if kind==6 {
        let points=field(params.as_ref().ok_or_else(||err("missing hit point"))?,"point")?.as_array().ok_or_else(||err("invalid hit point"))?;
        let x=points.first().and_then(Value::as_real).ok_or_else(||err("invalid hit x"))?;
        let y=points.get(1).and_then(Value::as_real).ok_or_else(||err("invalid hit y"))?;
        let point_value=a.object(&Value::String(format!("{{{x}, {y}}}")));let class=a.class("NSValue");
        let point=a.add(map(vec![("NS.pointval",point_value),("NS.special",Value::Integer(1.into())),("$class",class)]));
        let name=a.object(&Value::String("point".into()));let display=a.object(&Value::String("displayId".into()));let zero=a.object(&Value::Integer(0.into()));let class=a.class("NSDictionary");
        let params=a.add(map(vec![("NS.keys",Value::Array(vec![name,display])),("NS.objects",Value::Array(vec![point,zero])),("$class",class)]));
        let nonce=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos() as u64;
        let token=a.token(&map(vec![("objectID",Value::Integer(nonce.into()))]))?;(params,token)
    } else { (a.object(&params.unwrap_or_else(nil)),match token {Some(t)=>a.token(t)?,None=>Value::Uid(Uid::new(0))}) };
    let class=a.class("AXPTranslatorRequest");
    let root=a.add(map(vec![("requestType",Value::Integer(kind.into())),("clientType",Value::Integer(0.into())),("actionType",Value::Integer(action.into())),("attributeType",Value::Integer((if kind==2 {52}else{0}).into())),("translation",token),("parameters",params),("$class",class)]));
    a.finish(root)
}

struct Ax {
    _server: RemoteServerClient<Box<dyn ReadWrite>>,
    channel: OwnedChannel<Box<dyn ReadWrite>>,
    received: mpsc::Receiver<Vec<u8>>,
}
impl Ax {
    async fn connect(provider:&mut impl RsdProvider, hs:&RsdHandshake)->Result<Self,IdeviceError> {
        let port=hs.services.get(AX_SERVICE).ok_or_else(||err("AX service unavailable"))?.port;
        let stream=provider.connect_to_service_port(port).await?;
        let mut server=RemoteServerClient::with_label(stream,"calltap-ax");
        server.perform_handshake(None,Duration::from_secs(3)).await?;
        let mut channel=server.accept_owned_channel(0);
        let (tx,rx)=mpsc::channel(128);
        channel.set_incoming_handler(move |message:Message| {
            let tx=tx.clone(); async move {
                match message.data.as_ref().and_then(Value::as_string) {
                    Some("hostAPIVersion") => Ok(IncomingHandlerOutcome::Reply(ns_keyed_archive::encode::encode_to_bytes(Value::Integer(7.into())).map_err(|_|err("host API reply encoding"))?)),
                    Some("processDataFromRemoteDevice:") => {
                        let arg=message.aux.as_ref().and_then(|a|a.values.first()).ok_or_else(||err("missing AX callback data"))?;
                        let bytes=match arg { AuxValue::Array(bytes)=>ns_keyed_archive::decode::from_bytes(bytes).map_err(|_|err("AX callback decoding"))?, _=>return Err(err("AX callback is not archived data")) };
                        let bytes=bytes.into_data().ok_or_else(||err("AX callback is not data"))?;
                        if bytes.len()>LIMIT {return Err(err("AX callback size limit"));}
                        tx.try_send(bytes).map_err(|_|err("AX callback queue limit"))?;
                        Ok(IncomingHandlerOutcome::HandledNoReply)
                    }
                    _ => Ok(IncomingHandlerOutcome::Unhandled),
                }
            }
        }).await;
        let version=channel.call_method_with_reply(Some("deviceAPIVersion"),None).await?;
        if version.data.as_ref().and_then(number)!=Some(26) {return Err(err("unsupported AX API version"));}
        channel.call_method_with_reply(Some("clientNeedsAccessibility:"),Some(vec![AuxValue::archived_value(Value::Boolean(true))])).await?;
        Ok(Self { _server:server,channel,received:rx })
    }
    async fn read(&mut self,kind:u64,params:Option<Value>,token:Option<&Token>,action:u64)->Result<Value,IdeviceError> {
        let encoded=request(kind,params,token,action)?;
        let operation=async {
            self.channel.call_method_with_reply(Some("processDataFromHost:"),Some(vec![AuxValue::archived_value(Value::Data(encoded))])).await?;
            for _ in 0..128 {
                let data=self.received.recv().await.ok_or_else(||err("AX callback closed"))?;
                let response=decode(&data)?;
                if dict(&response)?.get("associatedRequestType").and_then(number)!=Some(kind) {continue;}
                let status=dict(&response)?.get("error").and_then(number);
                if kind==6 && status==Some(8) {return Err(err("hit-test unavailable (8)"));}
                if (kind==7 && status!=Some(0)) || status.unwrap_or(0)!=0 {return Err(err("AX request refused or action status unavailable"));}
                if kind==2 && (dict(&response)?.get("attribute").and_then(number)!=Some(52) || key(field(&response,"associatedTranslationObject")?)?!=key(token.ok_or_else(||err("missing snapshot token"))?)?) {return Err(err("snapshot identity mismatch"));}
                return Ok(dict(&response)?.get("resultData").cloned().unwrap_or_else(nil));
            }
            Err(err("AX unsolicited message limit"))
        };
        crate::time::timeout(Duration::from_secs(3),operation).await.map_err(|_|err("AX request timed out"))?
    }
    async fn snapshot(&mut self,root:&Token)->Result<Value,IdeviceError> {
        let options=map(vec![("attributes",Value::Array([2001u64,2002,2003,2004,5019,2006,2025,5003,5004,3003].into_iter().map(|v|Value::Integer(v.into())).collect())),("maxDepth",Value::Integer(48.into())),("maxChildren",Value::Integer(512.into())),("maxArrayCount",Value::Integer(512.into())),("traverseFromParentsToChildren",Value::Boolean(true)),("snapshotKeyHonorModalViews",Value::Boolean(false))]);
        self.read(2,Some(map(vec![("parameter",options)])),Some(root),0).await
    }
    async fn hit(&mut self,point:(f64,f64))->Result<Token,IdeviceError> {
        self.read(6,Some(map(vec![("point",Value::Array(vec![Value::Real(point.0),Value::Real(point.1)]))])),None,0).await
    }
    async fn close(&mut self) {
        let _=crate::time::timeout(Duration::from_secs(1),self.channel.call_method_with_reply(Some("clientNeedsAccessibility:"),Some(vec![AuxValue::archived_value(Value::Boolean(false))]))).await;
    }
}

#[derive(Clone,Copy,Debug,PartialEq)]
struct Rect {x:f64,y:f64,w:f64,h:f64}
impl Rect {
    fn parse(v:&Value)->Option<Self> {
        let d=v.as_dictionary()?;
        let f=|key:&str|->Option<f64>{let v=d.get(key)?;v.as_real().or_else(||number(v).map(|n|n as f64))};
        let r=Self{x:f("x")?,y:f("y")?,w:f("width")?,h:f("height")?};
        (r.x.is_finite()&&r.y.is_finite()&&r.w>0.0&&r.h>0.0&&r.w<10000.0&&r.h<10000.0).then_some(r)
    }
    fn center(self)->(f64,f64){(self.x+self.w/2.0,self.y+self.h/2.0)}
    fn same(self,other:Self)->bool{[self.x-other.x,self.y-other.y,self.w-other.w,self.h-other.h].iter().all(|v|v.abs()<0.1)}
}
#[derive(Clone)]
struct Node {token:Token,label:String,visible:bool,value:Option<Value>,traits:u64,frame:Option<Rect>}
fn nodes(snapshot:&Value,root:&Token)->Result<Vec<Node>,IdeviceError> {
    if key(field(snapshot,ELEMENT)?)?!=key(root)? {return Err(err("snapshot root changed"));}
    let mut output=Vec::new();let mut pending=vec![(snapshot,0)];
    while let Some((record,depth))=pending.pop() {
        if depth>48||output.len()>=512{return Err(err("snapshot limit"));}
        let token=field(record,ELEMENT)?.clone();let native=dict(field(record,ATTRS)?)?;
        let children=field(record,CHILDREN)?.as_array().ok_or_else(||err("invalid child list"))?;
        if number(field(record,CHILD_COUNT)?)!=Some(children.len() as u64){return Err(err("incomplete child list"));}
        if key(&token)?.0==key(root)?.0 {
            output.push(Node{token,label:native.get("2001").and_then(Value::as_string).unwrap_or("").into(),visible:yes(native.get("2025")),value:native.get("2006").cloned(),traits:native.get("2004").and_then(number).unwrap_or(0),frame:native.get("2003").and_then(Rect::parse)});
            pending.extend(children.iter().map(|child|(child,depth+1)));
        }
    }
    Ok(output)
}
fn norm(label:&str)->String {label.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()}
fn start(label:&str)->bool{matches!(norm(label).as_str(),"통화 녹음"|"통화녹음"|"통화 녹음 시작"|"녹음 시작"|"call recording"|"record call"|"start call recording"|"start recording")}
fn more(label:&str)->bool{matches!(norm(label).as_str(),"더 보기"|"더보기"|"more"|"more options")}
fn stop(label:&str)->bool{matches!(norm(label).as_str(),"통화 녹음 중지"|"통화 녹음 종료"|"통화 녹음 중단"|"녹음 중지"|"녹음 종료"|"녹음 중단"|"녹음 중"|"통화 녹음 중"|"stop recording"|"stop call recording"|"end recording"|"recording"|"recording in progress")}
fn inactive(value:Option<&Value>)->bool {match value {None=>true,Some(Value::String(s))=>matches!(s.trim().to_lowercase().as_str(),""|"0"|"off"|"$null"),Some(Value::Boolean(false))=>true,Some(v)=>number(v)==Some(0)}}
fn active(value:Option<&Value>)->bool {match value {Some(Value::Boolean(true))=>true,Some(Value::String(s))=>matches!(norm(s).as_str(),"1"|"on"|"selected"|"recording"|"녹음 중"|"켜짐"|"선택됨"),Some(v)=>number(v)==Some(1),None=>false}}
fn recording(nodes:&[Node])->bool {nodes.iter().any(|n|n.visible&&(stop(&n.label)||(start(&n.label)&&((n.traits&TRAIT_SELECTED)!=0||active(n.value.as_ref())))))}
#[derive(Clone,Copy)]
enum HitEvidence { SameElement, DifferentElement, Unavailable8 }
impl HitEvidence {
    fn permits(self,traits:u64)->bool {
        match self {
            Self::SameElement=>true,
            Self::DifferentElement=>false,
            // Proximity-blanked iOS 27 screens return error 8 even though the
            // native call button remains enabled/visible in AX. A controlled
            // device test confirmed native activation without waking display.
            Self::Unavailable8=>(traits&TRAIT_BUTTON)!=0,
        }
    }
}
fn unavailable_hit(error:&IdeviceError)->bool {
    matches!(error,IdeviceError::UnexpectedResponse(message) if message=="CallTap AX: hit-test unavailable (8)")
}
#[cfg(test)]
fn unique(nodes:&[Node],predicate:fn(&str)->bool)->Result<Option<Node>,IdeviceError> {
    Ok(match candidate(nodes,predicate)? {Candidate::One(node)=>Some(node),_=>None})
}
fn call_controls(nodes:&[Node])->bool {
    let names:HashSet<_>=nodes.iter().filter(|n|n.visible).map(|n|norm(&n.label)).collect();
    [vec!["mute","음소거","소리 끔"],vec!["keypad","키패드"],vec!["speaker","audio","스피커","오디오"]].iter().all(|family|family.iter().any(|name|names.contains(*name)))
}

async fn call_pid(provider:&mut impl RsdProvider,hs:&mut RsdHandshake)->Result<u64,IdeviceError> {
    let mut server=RemoteServerClient::connect_rsd(provider,hs).await?;
    server.perform_handshake(None,Duration::from_secs(3)).await?;
    let mut channel=server.make_channel("com.apple.instruments.server.services.processcontrol").await?;
    for bundle in ["com.apple.InCallService","com.apple.mobilephone"] {
        let reply=channel.call_method_with_reply(Some("processIdentifierForBundleIdentifier:"),Some(vec![AuxValue::archived_value(Value::String(bundle.into()))])).await?;
        if let Some(pid)=reply.data.as_ref().and_then(number).filter(|pid|*pid>0) {return Ok(pid);}
    }
    Err(err("native call app is not running"))
}

// Fixed, non-sensitive wait diagnostics. 100 + code means More was accepted
// in this connection, but its bounded follow-up ended with that wait reason.
const WAIT_MISSING: u32 = 10;
const WAIT_AMBIGUOUS: u32 = 11;
const WAIT_IDENTITY: u32 = 12;
const WAIT_DISABLED: u32 = 13;
const WAIT_FRAME: u32 = 14;
const WAIT_HIT: u32 = 15;
const WAIT_VALUE: u32 = 16;
const WAIT_GATE: u32 = 17;
const WAIT_ROOT: u32 = 18;

enum Candidate { Missing, Ambiguous, One(Node) }
fn candidate(nodes:&[Node],predicate:fn(&str)->bool)->Result<Candidate,IdeviceError> {
    let mut candidates=HashMap::new();
    for node in nodes.iter().filter(|node|node.visible&&predicate(&node.label)) {
        candidates.insert(key(&node.token)?,node.clone());
    }
    Ok(match candidates.len() {
        0=>Candidate::Missing,
        1=>Candidate::One(candidates.into_values().next().unwrap()),
        _=>Candidate::Ambiguous,
    })
}

enum InspectionStep { Waiting(u32), MoreSubmitted, StartSubmitted, AlreadyRecording }

async fn inspect_step(ax:&mut Ax,pid:u64,root:&Token,may_open_more:bool,
                      guard:&impl Fn(u32)->bool,start_reserved:&mut bool)->Result<InspectionStep,IdeviceError> {
    if !guard(0){return Ok(InspectionStep::Waiting(WAIT_GATE));}
    let snapshot=ax.snapshot(root).await?;let initial=nodes(&snapshot,root)?;
    if recording(&initial){return Ok(InspectionStep::AlreadyRecording);}
    let (target,is_start)=match candidate(&initial,start)? {
        Candidate::One(target)=>(target,true),
        Candidate::Ambiguous=>return Ok(InspectionStep::Waiting(WAIT_AMBIGUOUS)),
        Candidate::Missing=>{
            if !may_open_more||!call_controls(&initial){return Ok(InspectionStep::Waiting(WAIT_MISSING));}
            match candidate(&initial,more)? {
                Candidate::One(target)=>(target,false),
                Candidate::Missing=>return Ok(InspectionStep::Waiting(WAIT_MISSING)),
                Candidate::Ambiguous=>return Ok(InspectionStep::Waiting(WAIT_AMBIGUOUS)),
            }
        }
    };
    // A menu item can already be in AX while its UIKit transition is still
    // running. Require observations separated in time, even when the caller
    // starts with an already-open menu from an earlier inspection.
    if is_start {
        tokio::time::sleep(Duration::from_millis(150)).await;
        if !guard(0){return Ok(InspectionStep::Waiting(WAIT_GATE));}
    }
    let fresh=ax.snapshot(root).await?;let current=nodes(&fresh,root)?;
    if recording(&current){return Ok(InspectionStep::AlreadyRecording);}
    let confirmed=match candidate(&current,if is_start {start}else{more})? {
        Candidate::One(node)=>node,
        Candidate::Missing=>return Ok(InspectionStep::Waiting(WAIT_MISSING)),
        Candidate::Ambiguous=>return Ok(InspectionStep::Waiting(WAIT_AMBIGUOUS)),
    };
    if key(&confirmed.token)?!=key(&target.token)? {return Ok(InspectionStep::Waiting(WAIT_IDENTITY));}
    if is_start {
        let (Some(before),Some(after))=(target.frame,confirmed.frame) else {return Ok(InspectionStep::Waiting(WAIT_FRAME));};
        if !before.same(after){return Ok(InspectionStep::Waiting(WAIT_FRAME));}
    }
    let state=ax.read(5,Some(map(vec![("attributes",Value::Array([21u64,27,30,32,53].into_iter().map(|n|Value::Integer(n.into())).collect()))])),Some(&confirmed.token),0).await?;
    let live=dict(&state)?;
    if !yes(live.get("27"))||!yes(live.get("32")) {return Ok(InspectionStep::Waiting(WAIT_DISABLED));}
    if is_start && (yes(live.get("30"))||active(live.get("53"))) {return Ok(InspectionStep::AlreadyRecording);}
    if is_start && !inactive(live.get("53")) {return Ok(InspectionStep::Waiting(WAIT_VALUE));}
    let Some(frame)=confirmed.frame else {return Ok(InspectionStep::Waiting(WAIT_FRAME));};
    let Some(live_frame)=live.get("21").and_then(Rect::parse) else {return Ok(InspectionStep::Waiting(WAIT_FRAME));};
    if !frame.same(live_frame){return Ok(InspectionStep::Waiting(WAIT_FRAME));}
    let hit=match ax.hit(frame.center()).await {
        Ok(token)=>if key(&token)?==key(&confirmed.token)? {HitEvidence::SameElement}else{HitEvidence::DifferentElement},
        Err(error) if unavailable_hit(&error)=>HitEvidence::Unavailable8,
        Err(error)=>return Err(error),
    };
    if !hit.permits(confirmed.traits){return Ok(InspectionStep::Waiting(WAIT_HIT));}
    // No selector, visibility, frame, hit, proximity or current-call guard is
    // relaxed while waiting for the menu animation to settle.
    let latest=ax.read(1,Some(map(vec![("pid",Value::Integer(pid.into()))])),None,0).await?;
    if key(&latest)?!=key(root)? {return Ok(InspectionStep::Waiting(WAIT_ROOT));}
    if !guard(0){return Ok(InspectionStep::Waiting(WAIT_GATE));}
    let action=if is_start {2}else{1};
    if !guard(action){return Ok(InspectionStep::Waiting(WAIT_GATE));}
    if is_start { *start_reserved=true; }
    let accepted=ax.read(7,None,Some(&confirmed.token),5).await?;
    if !yes(Some(&accepted)){return Err(err("native press refused; action remains spent"));}
    Ok(if is_start {InspectionStep::StartSubmitted}else{InspectionStep::MoreSubmitted})
}

// This driver is shared with the fake-session regression tests. It owns the
// only transition which permits a More request, and never repeats a submitted
// recording action, even if its result is an error or times out.
trait MenuSession {
    fn permits(&self)->bool;
    fn start_reserved(&self)->bool;
    async fn step(&mut self,may_open_more:bool)->Result<InspectionStep,IdeviceError>;
    async fn observe_recording(&mut self)->Result<bool,IdeviceError>;
}
struct MenuTiming {
    interval:Duration, window:Duration, maximum_polls:usize, minimum_settle:Duration,
    confirmation_window:Duration, confirmation_interval:Duration, maximum_confirmations:usize,
}
impl Default for MenuTiming {
    fn default()->Self {
        Self{interval:Duration::from_millis(150),window:Duration::from_secs(5),maximum_polls:12,
             minimum_settle:Duration::from_secs(1),confirmation_window:Duration::from_secs(3),
             confirmation_interval:Duration::from_millis(150),maximum_confirmations:12}
    }
}
async fn confirm_submission(session:&mut impl MenuSession,timing:&MenuTiming)->u32 {
    let deadline=tokio::time::Instant::now()+timing.confirmation_window;
    for _ in 0..timing.maximum_confirmations {
        if !session.permits()||tokio::time::Instant::now()>=deadline {break;}
        let observed=tokio::time::timeout_at(deadline,session.observe_recording()).await;
        match observed {
            Ok(Ok(true))=>return 4,
            Ok(Ok(false))=>{},
            // A missing response cannot justify retransmitting a toggle.
            Ok(Err(_))|Err(_)=>break,
        }
        let remaining=deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero(){break;}
        tokio::time::sleep(timing.confirmation_interval.min(remaining)).await;
    }
    2 // Native ACK only; actual recording was not observed. Never retry.
}
async fn drive_menu(session:&mut impl MenuSession,may_open_more:bool,timing:MenuTiming)->Result<u32,IdeviceError> {
    let mut deadline=None;
    let mut polls=0;
    let mut last_wait=WAIT_MISSING;
    loop {
        let opened_more=deadline.is_some();
        if !session.permits(){return Ok(if opened_more {100+WAIT_GATE}else{WAIT_GATE});}
        let step=if let Some(end)=deadline {
            if polls>=timing.maximum_polls||tokio::time::Instant::now()>=end {return Ok(100+last_wait);}
            polls+=1;
            let result=tokio::time::timeout_at(end,session.step(false)).await;
            match result {
                Ok(result)=>result?,
                Err(_)=>{
                    if session.start_reserved(){return Err(err("menu follow-up timed out; reserved start must not be replayed"));}
                    return Ok(100+last_wait);
                }
            }
        } else {
            session.step(may_open_more).await?
        };
        match step {
            InspectionStep::StartSubmitted=>return Ok(confirm_submission(session,&timing).await),
            InspectionStep::AlreadyRecording=>return Ok(3),
            InspectionStep::Waiting(reason)=>{
                last_wait=reason;
                if !opened_more {return Ok(reason);}
                if reason==WAIT_GATE||reason==WAIT_ROOT {return Ok(100+reason);}
            }
            InspectionStep::MoreSubmitted=>{
                if opened_more {return Err(err("duplicate More outcome; action must not be replayed"));}
                deadline=Some(tokio::time::Instant::now()+timing.window);
                // AX acceptance precedes the menu's visual/interaction-ready
                // state. Do not immediately activate the newly exposed item.
                tokio::time::sleep(timing.minimum_settle.min(timing.window)).await;
            }
        }
        if let Some(end)=deadline {
            if polls>=timing.maximum_polls||tokio::time::Instant::now()>=end {return Ok(100+last_wait);}
            tokio::time::sleep(timing.interval.min(end.saturating_duration_since(tokio::time::Instant::now()))).await;
        }
    }
}

struct NativeMenuSession<'a,G:Fn(u32)->bool> {
    ax:&'a mut Ax, pid:u64, root:Token, guard:&'a G, start_reserved:bool,
}
impl<G:Fn(u32)->bool> MenuSession for NativeMenuSession<'_,G> {
    fn permits(&self)->bool {(self.guard)(0)}
    fn start_reserved(&self)->bool {self.start_reserved}
    async fn step(&mut self,may_open_more:bool)->Result<InspectionStep,IdeviceError> {
        inspect_step(self.ax,self.pid,&self.root,may_open_more,self.guard,&mut self.start_reserved).await
    }
    async fn observe_recording(&mut self)->Result<bool,IdeviceError> {
        if !(self.guard)(0){return Ok(false);}
        let latest=self.ax.read(1,Some(map(vec![("pid",Value::Integer(self.pid.into()))])),None,0).await?;
        if key(&latest)?!=key(&self.root)? {return Err(err("recording confirmation root changed"));}
        let snapshot=self.ax.snapshot(&self.root).await?;
        let current=nodes(&snapshot,&self.root)?;
        Ok((self.guard)(0)&&recording(&current))
    }
}

// Outcomes: 2 start ACKed but unconfirmed, 3 already recording, 4 observed
// recording after our single start, 10..18 fixed wait reason,
// 110..118 More accepted followed by bounded waiting. guard(1/2) reserves each
// action BEFORE wire dispatch. An ambiguous start is never replayed.
pub async fn inspect(provider:&mut impl RsdProvider,hs:&mut RsdHandshake,may_open_more:bool,guard:impl Fn(u32)->bool)->Result<u32,IdeviceError> {
    if !guard(0){return Ok(WAIT_GATE);}
    let pid=call_pid(provider,hs).await?;
    let mut ax=Ax::connect(provider,hs).await?;
    let result=async {
        let root=ax.read(1,Some(map(vec![("pid",Value::Integer(pid.into()))])),None,0).await?;
        if key(&root)?.0!=pid {return Ok(WAIT_ROOT);}
        let mut session=NativeMenuSession{ax:&mut ax,pid,root,guard:&guard,start_reserved:false};
        drive_menu(&mut session,may_open_more,MenuTiming::default()).await
    }.await;
    ax.close().await;result
}

#[cfg(test)]
mod tests {
    use super::*;
    fn token(pid:u64,id:u64)->Token{map(vec![("pid",Value::Integer(pid.into())),("objectID",Value::Integer(id.into()))])}
    fn node(id:u64,visible:bool)->Node{Node{token:token(42,id),label:"통화 녹음".into(),visible,value:None,traits:1,frame:None}}
    #[test] fn visible_parent_excludes_hidden_label(){let chosen=unique(&[node(1,true),node(2,false)],start).unwrap().unwrap();assert_eq!(key(&chosen.token).unwrap(),(42,1));}
    #[test] fn distinct_visible_candidates_are_ambiguous(){assert!(unique(&[node(1,true),node(2,true)],start).unwrap().is_none());}
    #[test] fn repeated_native_handle_is_one_target(){assert!(unique(&[node(1,true),node(1,true)],start).unwrap().is_some());}
    #[test] fn request_roundtrip_preserves_large_token(){let t=token(42,u64::MAX-1);let encoded=request(1,Some(map(vec![("pid",Value::Integer(42.into()))])),Some(&t),0).unwrap();let decoded=decode(&encoded).unwrap();assert_eq!(key(field(&decoded,"translation").unwrap()).unwrap(),(42,u64::MAX-1));}
    #[test] fn selected_recording_is_never_a_start(){let mut n=node(1,true);n.traits|=TRAIT_SELECTED;assert!(recording(&[n]));}
    #[test] fn image_trait_does_not_mean_selected(){let mut n=node(1,true);n.traits|=4;assert!(!recording(&[n]));}
    #[test] fn proximity_error8_allows_known_button_traits(){assert!(HitEvidence::Unavailable8.permits(8589934593));assert!(HitEvidence::Unavailable8.permits(8589934657));}
    #[test] fn error8_does_not_allow_a_text_or_unknown_target(){assert!(!HitEvidence::Unavailable8.permits(64));assert!(!HitEvidence::Unavailable8.permits(0));}
    #[test] fn wrong_hit_and_other_errors_never_use_fallback(){assert!(!HitEvidence::DifferentElement.permits(TRAIT_BUTTON));assert!(!unavailable_hit(&err("AX request timed out")));assert!(unavailable_hit(&err("hit-test unavailable (8)")));}
    #[test] fn unknown_value_is_not_inactive(){assert!(!inactive(Some(&Value::String("unknown".into()))));}
    #[test] fn unknown_value_does_not_claim_recording(){let mut n=node(1,true);n.value=Some(Value::String("unknown".into()));assert!(!recording(&[n]));}
    #[test] fn independent_python_request_matches(){let expected=decode(include_bytes!("calltap_ax_fixtures/application-request.bplist")).unwrap();let actual=decode(&request(1,Some(map(vec![("pid",Value::Integer(42.into()))])),None,0).unwrap()).unwrap();assert_eq!(actual,expected);}
    fn reference_token()->Token{map(vec![("pid",Value::Integer(42.into())),("objectID",Value::Integer((u64::MAX-1).into())),("rawElementData",Value::Data(b"fixture-only".to_vec())),("bridgeDelegateToken",nil()),("isApplicationElement",Value::Boolean(true)),("didPopuldateAppInfo",Value::Boolean(false))])}
    #[test] fn independent_state_request_matches(){let expected=decode(include_bytes!("calltap_ax_fixtures/state-request.bplist")).unwrap();let params=map(vec![("attributes",Value::Array([21u64,27,30,32,53].into_iter().map(|n|Value::Integer(n.into())).collect()))]);let actual=decode(&request(5,Some(params),Some(&reference_token()),0).unwrap()).unwrap();assert_eq!(actual,expected);}
    #[test] fn independent_press_request_matches(){let expected=decode(include_bytes!("calltap_ax_fixtures/press-request.bplist")).unwrap();let actual=decode(&request(7,None,Some(&reference_token()),5).unwrap()).unwrap();assert_eq!(actual,expected);}
    #[test] fn independent_hit_point_matches(){let expected=decode(include_bytes!("calltap_ax_fixtures/hit-request.bplist")).unwrap();let params=map(vec![("point",Value::Array(vec![Value::Real(123.5),Value::Real(67.25)]))]);let actual=decode(&request(6,Some(params),None,0).unwrap()).unwrap();assert_eq!(field(&actual,"parameters").unwrap(),field(&expected,"parameters").unwrap());}
    #[test] fn malformed_archive_is_rejected(){assert!(decode(b"not an archive").is_err());}

    enum Planned { More, Wait(u32), Start, Already, AmbiguousStart }
    struct FakeMenuSession {
        plan:std::collections::VecDeque<Planned>, allowed_more:Vec<bool>,
        more_presses:usize, start_presses:usize, reserved:bool,
        revoke_after:Option<usize>, observations:std::collections::VecDeque<bool>,
        confirmation_reads:usize, more_at:Option<tokio::time::Instant>,start_at:Option<tokio::time::Instant>,
    }
    impl FakeMenuSession {
        fn new(plan:Vec<Planned>)->Self {
            Self{plan:plan.into(),allowed_more:vec![],more_presses:0,start_presses:0,reserved:false,
                 revoke_after:None,observations:std::collections::VecDeque::new(),confirmation_reads:0,more_at:None,start_at:None}
        }
    }
    impl MenuSession for FakeMenuSession {
        fn permits(&self)->bool {self.revoke_after.map_or(true,|count|self.allowed_more.len()<count)}
        fn start_reserved(&self)->bool {self.reserved}
        async fn step(&mut self,may_open_more:bool)->Result<InspectionStep,IdeviceError> {
            self.allowed_more.push(may_open_more);
            match self.plan.pop_front().unwrap_or(Planned::Wait(WAIT_MISSING)) {
                Planned::More if may_open_more=>{
                    self.more_presses+=1;self.more_at=Some(tokio::time::Instant::now());Ok(InspectionStep::MoreSubmitted)
                },
                Planned::More=>Ok(InspectionStep::Waiting(WAIT_MISSING)),
                Planned::Wait(reason)=>Ok(InspectionStep::Waiting(reason)),
                Planned::Already=>Ok(InspectionStep::AlreadyRecording),
                Planned::Start=>{
                    assert!(!self.reserved,"driver replayed a reserved recording start");
                    self.reserved=true;self.start_presses+=1;self.start_at=Some(tokio::time::Instant::now());Ok(InspectionStep::StartSubmitted)
                }
                Planned::AmbiguousStart=>{
                    assert!(!self.reserved,"driver replayed a reserved recording start");
                    self.reserved=true;self.start_presses+=1;Err(err("test start reply lost"))
                }
            }
        }
        async fn observe_recording(&mut self)->Result<bool,IdeviceError> {
            self.confirmation_reads+=1;
            Ok(self.observations.pop_front().unwrap_or(false))
        }
    }
    fn fast_menu_timing(polls:usize)->MenuTiming {
        MenuTiming{interval:Duration::ZERO,window:Duration::from_secs(1),maximum_polls:polls,
                   minimum_settle:Duration::ZERO,confirmation_window:Duration::from_secs(1),
                   confirmation_interval:Duration::ZERO,maximum_confirmations:3}
    }
    #[tokio::test]
    async fn delayed_menu_reaches_record_without_reopening_more() {
        let mut session=FakeMenuSession::new(vec![Planned::More,Planned::Wait(WAIT_MISSING),Planned::Wait(WAIT_FRAME),Planned::Start]);
        assert_eq!(drive_menu(&mut session,true,fast_menu_timing(5)).await.unwrap(),2);
        assert_eq!(session.allowed_more,vec![true,false,false,false]);
        assert_eq!((session.more_presses,session.start_presses),(1,1));
    }
    #[tokio::test]
    async fn still_visible_more_control_does_not_get_pressed_again() {
        let mut session=FakeMenuSession::new(vec![Planned::More,Planned::More,Planned::Start]);
        assert_eq!(drive_menu(&mut session,true,fast_menu_timing(5)).await.unwrap(),2);
        assert_eq!((session.more_presses,session.start_presses),(1,1));
        assert_eq!(session.allowed_more,vec![true,false,false]);
    }
    #[tokio::test]
    async fn recording_started_manually_while_menu_settles_is_not_toggled() {
        let mut session=FakeMenuSession::new(vec![Planned::More,Planned::Wait(WAIT_DISABLED),Planned::Already,Planned::Start]);
        assert_eq!(drive_menu(&mut session,true,fast_menu_timing(5)).await.unwrap(),3);
        assert_eq!((session.more_presses,session.start_presses),(1,0));
        assert_eq!(session.plan.len(),1);
    }
    #[tokio::test]
    async fn initially_active_recording_sends_no_action() {
        let mut session=FakeMenuSession::new(vec![Planned::Already,Planned::More]);
        assert_eq!(drive_menu(&mut session,true,fast_menu_timing(5)).await.unwrap(),3);
        assert_eq!((session.more_presses,session.start_presses),(0,0));
        assert_eq!(session.plan.len(),1);
    }
    #[tokio::test]
    async fn ended_or_paused_call_revokes_followup_before_record_press() {
        let mut session=FakeMenuSession::new(vec![Planned::More,Planned::Start]);
        session.revoke_after=Some(1);
        assert_eq!(drive_menu(&mut session,true,fast_menu_timing(5)).await.unwrap(),100+WAIT_GATE);
        assert_eq!((session.more_presses,session.start_presses),(1,0));
    }
    #[tokio::test]
    async fn menu_poll_budget_reports_last_reason_without_extra_press() {
        let mut session=FakeMenuSession::new(vec![Planned::More,Planned::Wait(WAIT_FRAME),Planned::Wait(WAIT_DISABLED),Planned::Start]);
        assert_eq!(drive_menu(&mut session,true,fast_menu_timing(2)).await.unwrap(),100+WAIT_DISABLED);
        assert_eq!(session.allowed_more.len(),3);
        assert_eq!((session.more_presses,session.start_presses),(1,0));
        assert_eq!(session.plan.len(),1);
    }
    #[tokio::test]
    async fn ambiguous_record_reply_is_never_retried() {
        let mut session=FakeMenuSession::new(vec![Planned::More,Planned::AmbiguousStart,Planned::Start]);
        assert!(drive_menu(&mut session,true,fast_menu_timing(5)).await.is_err());
        assert_eq!((session.more_presses,session.start_presses),(1,1));
        assert!(session.reserved);
        assert_eq!(session.plan.len(),1);
    }
    #[tokio::test]
    async fn previously_reserved_more_cannot_be_reopened_by_a_later_inspection() {
        let mut session=FakeMenuSession::new(vec![Planned::More,Planned::Start]);
        assert_eq!(drive_menu(&mut session,false,fast_menu_timing(5)).await.unwrap(),WAIT_MISSING);
        assert_eq!((session.more_presses,session.start_presses),(0,0));
        assert_eq!(session.plan.len(),1);
    }
    #[tokio::test]
    async fn native_start_ack_without_recording_effect_stays_unconfirmed() {
        let mut session=FakeMenuSession::new(vec![Planned::More,Planned::Start,Planned::Start]);
        assert_eq!(drive_menu(&mut session,true,fast_menu_timing(5)).await.unwrap(),2);
        assert_eq!(session.confirmation_reads,3);
        assert_eq!((session.more_presses,session.start_presses),(1,1));
        assert_eq!(session.plan.len(),1);
    }
    #[tokio::test]
    async fn delayed_recording_effect_is_confirmed_without_another_press() {
        let mut session=FakeMenuSession::new(vec![Planned::More,Planned::Start,Planned::Start]);
        session.observations=vec![false,false,true].into();
        assert_eq!(drive_menu(&mut session,true,fast_menu_timing(5)).await.unwrap(),4);
        assert_eq!(session.confirmation_reads,3);
        assert_eq!((session.more_presses,session.start_presses),(1,1));
        assert_eq!(session.plan.len(),1);
    }
    #[tokio::test]
    async fn more_menu_has_a_minimum_settling_dwell_before_record_press() {
        let mut session=FakeMenuSession::new(vec![Planned::More,Planned::Start]);
        let mut timing=fast_menu_timing(5);
        timing.minimum_settle=Duration::from_millis(30);
        assert_eq!(drive_menu(&mut session,true,timing).await.unwrap(),2);
        assert!(session.start_at.unwrap().duration_since(session.more_at.unwrap())>=Duration::from_millis(30));
        assert_eq!((session.more_presses,session.start_presses),(1,1));
    }
}
