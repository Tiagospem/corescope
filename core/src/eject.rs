//! What keeps a volume from ejecting: processes with files open on it, a working folder inside
//! it (a shell, an editor, a dev server) or a program running from it. Only the current user's
//! processes can be read; system services (Spotlight's mds, fseventsd) can hold a volume too, and
//! macOS names them when an eject fails.
use crate::Process;
use crate::os::{os_open_under, string};
use serde::Serialize;
use std::ffi::CString;

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Holder {
    pub pid: i32,
    pub name: String,
    /// "program" (runs from the volume), "working folder" or "open files".
    pub reason: &'static str,
    /// Open files on the volume (0 for a working folder or program only).
    pub files: u32,
    /// One path on the volume it holds.
    pub example: String,
    /// CoreScope may stop it (the user's own, not protected).
    pub eligible: bool,
    pub origin: Option<String>,
}

/// Whether `path` is the mount point or inside it.
pub fn inside(path: &str, mount: &str) -> bool {
    let mount = mount.trim_end_matches('/');
    !mount.is_empty()
        && (path == mount
            || path
                .strip_prefix(mount)
                .is_some_and(|rest| rest.starts_with('/')))
}

/// Holders of `mount`, programs first, then by open files.
pub fn holders(mount: &str, processes: &[Process]) -> Vec<Holder> {
    let Ok(prefix) = CString::new(mount.trim_end_matches('/')) else {
        return vec![];
    };
    let mut out = vec![];
    for p in processes {
        let mut example = [0 as std::ffi::c_char; 1024];
        let files = unsafe { os_open_under(p.pid, prefix.as_ptr(), example.as_mut_ptr(), 1024) };
        let files = files.max(0) as u32;
        let (reason, example) = if inside(&p.path, mount) {
            ("program", p.path.clone())
        } else if files > 0 {
            ("open files", string(&example))
        } else if inside(&p.cwd, mount) {
            ("working folder", p.cwd.clone())
        } else {
            continue;
        };
        out.push(Holder {
            pid: p.pid,
            name: p.name.clone(),
            reason,
            files,
            example,
            eligible: p.eligible,
            origin: p.origin.as_ref().map(|o| o.label.to_string()),
        });
    }
    let rank = |h: &Holder| match h.reason {
        "program" => 0,
        "open files" => 1,
        _ => 2,
    };
    out.sort_by_key(|h| (rank(h), std::cmp::Reverse(h.files)));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_inside_a_mount() {
        assert!(inside("/Volumes/HD Externo/x", "/Volumes/HD Externo"));
        assert!(inside("/Volumes/HD Externo", "/Volumes/HD Externo/"));
        assert!(!inside("/Volumes/HD Externo 2/x", "/Volumes/HD Externo"));
        assert!(!inside("/Users/u", ""));
    }

    #[test]
    fn this_test_holds_its_own_temp_folder() {
        let dir = std::env::temp_dir().join(format!("corescope-eject-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("held.txt");
        let _open = std::fs::File::create(&file).unwrap();
        let dir = dir.canonicalize().unwrap();
        let mut me = crate::process_fixture();
        me.pid = std::process::id() as i32;
        me.path = "/usr/bin/true".into();
        me.cwd = "/".into();
        let found = holders(&dir.to_string_lossy(), &[me]);
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0].reason, "open files");
        assert!(found[0].example.ends_with("held.txt"));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
