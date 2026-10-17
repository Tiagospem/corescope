fn main() {
    println!("cargo:rerun-if-changed=src/macos.c");
    println!("cargo:rerun-if-changed=src/macos.h");
    // System libsqlite3 for the opt-in history; the app links it with -lsqlite3.
    println!("cargo:rustc-link-lib=sqlite3");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        // CoreScope runs only on macOS. Elsewhere (the Linux image in .oss-scanner/) the C adapter is replaced by
        // stubs that report every OS query as unavailable, so the portable Rust builds and its tests run.
        stubs();
        return;
    }
    cc::Build::new()
        .file("src/macos.c")
        .flag("-mmacosx-version-min=14.0")
        .warnings(true)
        .compile("macos");
    println!("cargo:rustc-link-lib=framework=IOKit");
    println!("cargo:rustc-link-lib=framework=CoreFoundation");
}

/// Writes one failing definition for every `os_*` prototype in macos.h (void ones do nothing) and compiles them.
fn stubs() {
    let header = std::fs::read_to_string("src/macos.h").expect("src/macos.h");
    let mut c = format!("#include \"{}/src/macos.h\"\n", env!("CARGO_MANIFEST_DIR"));
    for line in header.lines().map(str::trim) {
        let Some(open) = line.find("os_") else {
            continue;
        };
        if !line.ends_with(");") || line.starts_with("//") {
            continue;
        }
        let returns = line[..open].trim();
        let body = if returns == "void" { "" } else { "return -1;" };
        c += &format!("{}{{ {body} }}\n", line.trim_end_matches(';'));
    }
    let out = std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("stubs.c");
    std::fs::write(&out, c).unwrap();
    cc::Build::new()
        .file(&out)
        .flag_if_supported("-Wno-unused-parameter")
        .compile("macos");
}
