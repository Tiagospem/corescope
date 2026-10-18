//! The largest files in the home folder (DMGs, videos, VM images, dumps, models), with what they
//! are and whether an app manages them (deleting Docker's disk image or a Photos library from
//! Finder breaks that app, so those are only shown). Read-only; the app moves the ones the user
//! picks to the Trash.
use serde::Serialize;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct BigFile {
    pub path: String,
    /// Allocated bytes (a sparse disk image counts what it really uses).
    pub bytes: u64,
    /// Seconds since 1970.
    pub modified: i64,
    /// "disk image", "video", "archive", "virtual machine", "database dump", "model", "log" or
    /// "file".
    pub kind: &'static str,
    /// The app that owns it; such files are not offered for the Trash.
    pub managed_by: Option<&'static str>,
}
#[derive(Clone, Debug, Serialize)]
pub struct Scan {
    pub files: Vec<BigFile>,
    pub scanned_files: u64,
    /// The walk stopped at its time limit; the list may miss files.
    pub partial: bool,
    pub seconds: f64,
}

pub fn kind(path: &Path) -> &'static str {
    if path.to_string_lossy().contains("/huggingface/hub/") {
        return "model";
    }
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    let ext = name.rsplit('.').next().unwrap_or("");
    match ext {
        "dmg" | "iso" | "img" | "pkg" | "xip" | "ipsw" => "disk image",
        "mp4" | "mov" | "mkv" | "avi" | "m4v" | "webm" | "prores" => "video",
        "zip" | "tar" | "tgz" | "xz" | "7z" | "rar" | "bz2" | "zst" => "archive",
        "gz" if name.ends_with(".sql.gz") => "database dump",
        "gz" => "archive",
        "vmdk" | "qcow2" | "vdi" | "vhd" | "vhdx" | "hdd" | "raw" | "utm" | "pvm" => {
            "virtual machine"
        }
        "sql" | "dump" | "bak" | "sqlite" | "db" => "database dump",
        "gguf" | "safetensors" | "ckpt" | "pt" | "onnx" | "mlmodel" => "model",
        "log" => "log",
        _ => "file",
    }
}

/// The app that manages files under this path, when removing one by hand would break it.
pub fn managed_by(path: &str) -> Option<&'static str> {
    [
        ("/Library/Containers/com.docker.docker/", "Docker Desktop"),
        (
            "/Library/Group Containers/HUAQ24HBR6.dev.orbstack/",
            "OrbStack",
        ),
        ("/.colima/", "Colima"),
        ("/.ollama/", "Ollama"),
        (
            "/huggingface/hub/",
            "Hugging Face (huggingface-cli delete-cache)",
        ),
        ("/.lmstudio/", "LM Studio"),
        ("/Library/Developer/", "Xcode"),
        (".photoslibrary/", "Photos"),
        ("/Library/Mail/", "Mail"),
        ("/Library/Messages/", "Messages"),
        ("/Library/Application Support/Claude/", "Claude"),
        ("/Library/Mobile Documents/", "iCloud Drive"),
        (
            "/Library/Application Support/MobileSync/",
            "iPhone backups (Finder)",
        ),
        ("/Parallels/", "Parallels"),
        ("/Library/Containers/com.utmapp.UTM/", "UTM"),
    ]
    .iter()
    .find(|(part, _)| path.contains(part))
    .map(|(_, app)| *app)
}

/// Files of at least `min` bytes under the roots, largest first, up to `limit`. The walk never
/// follows symlinks below a root, skips the Trash and stops after `budget`.
pub fn scan(roots: &[PathBuf], min: u64, limit: usize, budget: Duration) -> Scan {
    let started = Instant::now();
    let mut files = vec![];
    let mut scanned = 0u64;
    let mut partial = false;
    // Roots may be symlinks (Downloads moved to another drive): resolve them once. Each folder
    // is walked only on its root's filesystem, so mounts inside it (OrbStack's NFS, disk
    // images, network shares) are never entered.
    let mut stack: Vec<(PathBuf, u64)> = vec![];
    let mut seen_roots = std::collections::HashSet::new();
    for r in roots {
        let r = r.canonicalize().unwrap_or_else(|_| r.clone());
        if let Ok(meta) = std::fs::metadata(&r)
            && seen_roots.insert(r.clone())
        {
            stack.push((r, meta.dev()));
        }
    }
    'walk: while let Some((dir, dev)) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for e in entries.flatten() {
            if started.elapsed() > budget {
                partial = true;
                break 'walk;
            }
            let Ok(meta) = e.metadata() else { continue };
            if meta.is_dir() {
                let name = e.file_name();
                let name = name.to_string_lossy();
                // Cloud placeholders (OneDrive, Dropbox, iCloud via File Provider) can block
                // while they download; dependency and git folders hold nothing to pick by hand.
                let skip = matches!(
                    name.as_ref(),
                    ".Trash" | "node_modules" | ".git" | "CloudStorage" | "Mobile Documents"
                );
                if !skip && meta.dev() == dev {
                    stack.push((e.path(), dev));
                }
                continue;
            }
            if !meta.is_file() {
                continue;
            }
            scanned += 1;
            let bytes = meta.blocks() * 512;
            if bytes >= min {
                let path = e.path();
                let text = path.to_string_lossy().into_owned();
                files.push(BigFile {
                    kind: kind(&path),
                    managed_by: managed_by(&text),
                    path: text,
                    bytes,
                    modified: meta.mtime(),
                });
            }
        }
    }
    files.sort_by_key(|f| std::cmp::Reverse(f.bytes));
    files.truncate(limit);
    Scan {
        files,
        scanned_files: scanned,
        partial,
        seconds: started.elapsed().as_secs_f64(),
    }
}

/// The home folder plus any top-level symlinked folders it points elsewhere (Downloads moved to
/// another drive), so those are searched too.
pub fn default_roots(home: &Path) -> Vec<PathBuf> {
    let mut roots = vec![home.to_path_buf()];
    for e in std::fs::read_dir(home).into_iter().flatten().flatten() {
        let target = e.path().canonicalize().unwrap_or_default();
        // Links into cloud storage (OneDrive, Dropbox) stay out: listing them can download files.
        if e.file_type().is_ok_and(|t| t.is_symlink())
            && target.is_dir()
            && !target.to_string_lossy().contains("/Library/CloudStorage/")
        {
            roots.push(e.path());
        }
    }
    roots
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kinds_and_owners() {
        assert_eq!(kind(Path::new("/x/Xcode_16.xip")), "disk image");
        assert_eq!(kind(Path::new("/x/backup.sql.gz")), "database dump");
        assert_eq!(kind(Path::new("/x/logs.tar.gz")), "archive");
        assert_eq!(kind(Path::new("/x/ubuntu.qcow2")), "virtual machine");
        assert_eq!(kind(Path::new("/x/llama.gguf")), "model");
        assert_eq!(
            managed_by("/Users/u/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"),
            Some("Docker Desktop")
        );
        assert_eq!(managed_by("/Users/u/Downloads/movie.mp4"), None);
    }

    #[test]
    fn finds_large_files_without_following_links() {
        let root = std::env::temp_dir().join(format!("corescope-large-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("a/b")).unwrap();
        std::fs::create_dir_all(root.join(".Trash")).unwrap();
        std::fs::create_dir_all(root.join("app/node_modules/pkg")).unwrap();
        std::fs::write(
            root.join("app/node_modules/pkg/huge.bin"),
            vec![1u8; 300 * 1024],
        )
        .unwrap();
        std::fs::write(root.join("a/b/big.dmg"), vec![1u8; 300 * 1024]).unwrap();
        std::fs::write(root.join("a/small.txt"), vec![1u8; 10]).unwrap();
        std::fs::write(root.join(".Trash/old.mov"), vec![1u8; 300 * 1024]).unwrap();
        std::os::unix::fs::symlink(root.join("a"), root.join("a/b/loop")).unwrap();
        let s = scan(
            std::slice::from_ref(&root),
            256 * 1024,
            10,
            Duration::from_secs(10),
        );
        assert_eq!(s.files.len(), 1, "{:?}", s.files);
        assert!(s.files[0].path.ends_with("big.dmg"));
        assert_eq!(s.files[0].kind, "disk image");
        assert!(!s.partial);
        std::fs::remove_dir_all(root).unwrap();
    }
}
