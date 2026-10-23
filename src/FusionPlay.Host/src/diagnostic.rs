use fusionplay_host::*;
use std::{sync::Arc, time::Duration};
struct Printer;
impl StateListener for Printer {
    fn on_state(&self, s: Snapshot) {
        println!(
            "{:?} {} queue={:.1}ms underruns={}",
            s.phase, s.message, s.queue_ms, s.underruns
        );
    }
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("--devices") {
        println!(
            "Networks: {:#?}\nOutputs: {:#?}",
            network_interfaces()?,
            audio_devices()?
        );
        return Ok(());
    }
    let dir = args
        .get(1)
        .ok_or("Usage: fusionplay-diagnostic DATA_DIRECTORY [seconds] or --devices")?;
    let seconds: u64 = args.get(2).map(|s| s.parse()).transpose()?.unwrap_or(10);
    let receiver: Arc<Receiver> = Receiver::new(dir.clone())?;
    let token = receiver.subscribe(Box::new(Printer));
    receiver.start(receiver.settings())?;
    std::thread::sleep(Duration::from_secs(seconds));
    receiver.stop();
    receiver.unsubscribe(token);
    Ok(())
}
