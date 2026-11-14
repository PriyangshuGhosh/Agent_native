//! Crash-safe file transactions, shared by agentd (capability installs) and agentd-broker (system config changes):
//! write-ahead backups under a transaction directory, atomic durable writes, rollback, and recovery at the next start.
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

type Res<T> = Result<T, Box<dyn std::error::Error>>;

/// Every path a transaction touched, with its (bytes, mode) before it (None = it did not exist).
pub type Journal = Vec<(PathBuf, Option<(Vec<u8>, u32)>)>;

pub fn tmp_of(path: &Path) -> PathBuf {
    let mut t = path.as_os_str().to_owned();
    t.push(".agentd-tmp");
    t.into()
}

/// Atomically and durably replaces `path`: fresh temp file, fsync, rename in the same directory, fsync the directory.
pub fn put(path: &Path, data: &[u8], mode: u32) -> Res<()> {
    let tmp = tmp_of(path);
    let dir = path.parent().ok_or("path has no parent")?;
    let r = (|| -> Res<()> {
        fs::create_dir_all(dir)?;
        let _ = fs::remove_file(&tmp);
        // create_new (O_EXCL) never follows a planted symlink.
        let mut f = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)?;
        f.write_all(data)?;
        f.set_permissions(fs::Permissions::from_mode(mode))?;
        f.sync_all()?;
        fs::rename(&tmp, path)?;
        Ok(File::open(dir)?.sync_all()?)
    })();
    if r.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    r
}

pub fn snapshot(path: &Path) -> Option<(Vec<u8>, u32)> {
    Some((fs::read(path).ok()?, fs::metadata(path).ok()?.permissions().mode() & 0o7777))
}

/// Write-ahead: saves `path`'s prior state under `txn` (backup file + journal) before writing it, so a transaction
/// cut short by a crash is rolled back by recover() at the next start.
pub fn staged_put(j: &mut Journal, txn: &Path, path: &Path, data: &[u8], mode: u32) -> Res<()> {
    let prior = snapshot(path);
    if let Some((b, m)) = &prior {
        put(&txn.join(j.len().to_string()), b, *m)?;
    }
    j.push((path.into(), prior));
    let entries: Vec<(&PathBuf, bool)> = j.iter().map(|(p, prior)| (p, prior.is_some())).collect();
    put(&txn.join("journal.json"), &serde_json::to_vec(&entries)?, 0o600)?;
    put(path, data, mode)
}

/// Undoes a transaction, newest change first.
pub fn rollback(j: &Journal) -> Res<()> {
    for (p, prior) in j.iter().rev() {
        match prior {
            Some((b, m)) => put(p, b, *m)?,
            None => fs::remove_file(p).or_else(|e| if e.kind() == std::io::ErrorKind::NotFound { Ok(()) } else { Err(e) })?,
        }
    }
    Ok(())
}

/// Closes a transaction (after commit or rollback): its journal goes, durably.
pub fn end_txn(txn: &Path) -> Res<()> {
    match fs::remove_dir_all(txn) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e.into()),
        _ => {}
    }
    Ok(File::open(txn.parent().ok_or("txn has no parent")?)?.sync_all()?)
}

/// Rolls back a transaction a crash left open in `txn`. Returns (package, journal) if there was one.
pub fn recover(txn: &Path) -> Res<Option<(String, Journal)>> {
    let entries: Vec<(PathBuf, bool)> = match fs::read(txn.join("journal.json")) {
        Ok(b) => serde_json::from_slice(&b)?,
        // No journal yet: nothing outside txn was touched.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return end_txn(txn).map(|_| None),
        Err(e) => return Err(e.into()),
    };
    let j: Journal = entries.into_iter().enumerate().map(|(i, (p, had))| -> Res<_> {
        let _ = fs::remove_file(tmp_of(&p));
        Ok((p, if had { Some(snapshot(&txn.join(i.to_string())).ok_or("journal backup missing")?) } else { None }))
    }).collect::<Res<_>>()?;
    rollback(&j)?;
    let pkg = fs::read_to_string(txn.join("package")).unwrap_or_default();
    end_txn(txn)?;
    Ok(Some((pkg, j)))
}

