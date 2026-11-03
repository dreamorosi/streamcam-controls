fn main() {
    if let Err(error) = streamcam::run() {
        eprintln!("streamcam: {error}");
        std::process::exit(1);
    }
}
