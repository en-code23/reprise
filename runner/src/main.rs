mod console;
mod finish;
mod finish_hooks;
mod policy;
mod providers;
mod rpc;
mod session;

use base64::Engine;

#[tokio::main]
async fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    let result=async {
        match args.first().map(String::as_str){
            Some("completion-hooks")=>{match finish_hooks::command(&args){Ok(message)=>{println!("{message}");Ok(())},Err(error)=>{println!("{error}");Err("The completion connection could not be updated.".into())}}},
            Some("run")=>{
                let index=args.iter().position(|x|x=="--request").ok_or("Missing managed-session request.")?;
                let encoded=args.get(index+1).filter(|s|s.len()<16384).ok_or("Invalid managed-session request.")?;
                let bytes=base64::engine::general_purpose::STANDARD.decode(encoded).map_err(|_|"Invalid managed-session request.")?;
                let request:providers::Request=serde_json::from_slice(&bytes).map_err(|_|"Invalid managed-session request.")?;
                request.validate()?;
                #[cfg(unix)] {
                    let mut hangup=tokio::signal::unix::signal(tokio::signal::unix::SignalKind::hangup()).map_err(|_|"Could not watch terminal closure.")?;
                    let mut terminate=tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).map_err(|_|"Could not watch session shutdown.")?;
                    tokio::select! {result=session::run(request)=>result,_=hangup.recv()=>Ok(()),_=terminate.recv()=>Ok(())}
                }
                #[cfg(not(unix))] {session::run(request).await}
            },
            Some("probe")=>{
                let provider=args.get(1).ok_or("Missing provider.")?;
                let config_path=args.iter().position(|x|x=="--config").and_then(|i|args.get(i+1)).map(std::path::PathBuf::from);
                let state=match provider.as_str(){
                    "codex"=>providers::probe_codex().await?,
                    "claude"=>{
                        let path=config_path.ok_or("Missing usage configuration.")?;
                        let config=providers::settings(&path)?;
                        if !config.preferences.enabled{return Err("Automatic selection is disabled.".into());}
                        let request=providers::Request{provider:provider.clone(),session_id:uuid::Uuid::nil().to_string(),directory:std::env::temp_dir(),config_path:path,project_key:String::new(),host_probe:None};
                        providers::claude_usage(&request,&config).await?
                    },
                    "grok"=>{
                        let mut state=policy::State{provider:provider.clone(),observed_at:Some(policy::now()),status:"Grok usage is unavailable until its CLI exposes plan percentages. Managed sessions read models and effort levels from ACP; unknown usage uses a conservative choice.".into(),..Default::default()};
                        providers::grok_usage(&mut state).await;state
                    },
                    _=>return Err("Unsupported provider.".into())
                };
                println!("{}",serde_json::to_string(&state).map_err(|_|"Usage metadata could not be encoded.")?);Ok(())
            },
            Some("plan")=>{
                let index=args.iter().position(|x|x=="--request").ok_or("Missing plan request.")?;
                let encoded=args.get(index+1).filter(|s|s.len()<16384).ok_or("Invalid plan request.")?;
                let bytes=base64::engine::general_purpose::STANDARD.decode(encoded).map_err(|_|"Invalid plan request.")?;
                let request:providers::Request=serde_json::from_slice(&bytes).map_err(|_|"Invalid plan request.")?;request.validate()?;
                let config=providers::settings(&request.config_path)?;
                let mut state=providers::cached(&request.config_path,&request.provider).or_else(||config.states.iter().find(|s|s.provider==request.provider).cloned()).unwrap_or(policy::State{provider:request.provider.clone(),..Default::default()});
                providers::apply_roles(&mut state,&config);
                let directory=request.directory.clone();let assessment=tokio::task::spawn_blocking(move||providers::assess(&directory)).await.map_err(|_|"Project assessment failed.")?;
                let hint=config.preferences.work_hints.get(&request.key()).map(String::as_str).unwrap_or("automatic");
                let decision=policy::decide(&assessment,&state,&config.preferences,hint,policy::now());
                println!("{}",serde_json::to_string(&decision).map_err(|_|"Model choice could not be encoded.")?);Ok(())
            },
            Some("--version")|Some("version")=>{println!("Reprise managed sessions {}",env!("CARGO_PKG_VERSION"));Ok(())},
            _=>{eprintln!("Reprise managed sessions\nRun from Reprise's Resume button. Commands: run, probe, plan, --version.");Err("No managed session was supplied.".into())}
        }
    }.await;
    if let Err(error) = result {
        eprintln!("Reprise: {error}");
        std::process::exit(1);
    }
    // The terminal-input thread is deliberately independent of the async runtime.
    // All provider handles are dropped before returning here.
    std::process::exit(0);
}
