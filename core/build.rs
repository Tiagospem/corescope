fn main() {
    cc::Build::new()
        .file("src/macos.c")
        .flag("-mmacosx-version-min=14.0")
        .warnings(true)
        .compile("macos");
    println!("cargo:rustc-link-lib=framework=IOKit");
    println!("cargo:rustc-link-lib=framework=CoreFoundation");
    // System libsqlite3 for the opt-in history; the app links it with -lsqlite3.
    println!("cargo:rustc-link-lib=sqlite3");
    println!("cargo:rerun-if-changed=src/macos.c");
    println!("cargo:rerun-if-changed=src/macos.h");
}
