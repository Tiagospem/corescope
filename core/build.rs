fn main() {
    cc::Build::new()
        .file("src/macos.c")
        .flag("-mmacosx-version-min=14.0")
        .warnings(true)
        .compile("macos");
    println!("cargo:rustc-link-lib=framework=IOKit");
    println!("cargo:rustc-link-lib=framework=CoreFoundation");
    println!("cargo:rerun-if-changed=src/macos.c");
    println!("cargo:rerun-if-changed=src/macos.h");
}
