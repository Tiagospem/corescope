//! Prints two container reads 5 s apart (the second has CPU deltas). Local sockets only.
//! `containers <stop|restart> <id>` acts on one container instead (manual testing).
use corescope::containers::{Reader, act};
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let [action, id] = args.as_slice() {
        println!("{:?}", act(id, action));
        return;
    }
    let mut r = Reader::default();
    let start = std::time::Instant::now();
    let _ = r.read(true);
    eprintln!("first read: {:?}", start.elapsed());
    std::thread::sleep(std::time::Duration::from_secs(5));
    let start = std::time::Instant::now();
    let report = r.read(true);
    eprintln!("second read: {:?}", start.elapsed());
    println!("{}", serde_json::to_string_pretty(&report).unwrap());
}
