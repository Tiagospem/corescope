use corescope::{Collector, Config};
fn main() {
    let mut c = Collector::default();
    let _ = c.sample(Config::default());
    std::thread::sleep(std::time::Duration::from_secs(2));
    let s = c.sample(Config::default());
    println!("{}", serde_json::to_string(&s).unwrap());
}
