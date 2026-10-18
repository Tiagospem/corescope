//! SSD health from the NVMe SMART / Health log page (NVM Express 1.0c §5.10.1.2), the same page
//! the system reads for temperature: wear (percentage of rated endurance used), available spare,
//! data written and read, power cycles, power-on hours, unsafe shutdowns and media errors.
//! Read-only; disks without NVMe SMART (USB enclosures, SATA, disk images) say so.
use crate::os::{RawDisk, RawNvmeHealth, os_disks, os_nvme_health, string};
use serde::Serialize;

/// One NVMe data unit is 1000 blocks of 512 bytes.
pub const DATA_UNIT: u64 = 512_000;

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Health {
    pub id: String,
    pub name: String,
    /// "ok", "unsupported", "not permitted" or "unavailable".
    pub status: &'static str,
    /// "good", "watch" or "replace"; None when nothing could be read.
    pub verdict: Option<&'static str>,
    pub percentage_used: Option<u8>,
    pub available_spare: Option<u8>,
    pub spare_threshold: Option<u8>,
    pub written_bytes: Option<u64>,
    pub read_bytes: Option<u64>,
    pub power_cycles: Option<u64>,
    pub power_on_hours: Option<u64>,
    pub unsafe_shutdowns: Option<u64>,
    pub media_errors: Option<u64>,
    pub error_log_entries: Option<u64>,
    pub temperature_c: Option<f64>,
    /// Plain-English reasons behind the verdict (critical warnings first).
    pub notes: Vec<String>,
}

/// The verdict and its reasons for one SMART page.
pub fn assess(h: &RawNvmeHealth) -> (&'static str, Vec<String>) {
    let mut notes = vec![];
    let mut verdict = "good";
    let mut worse = |v: &'static str| {
        if v == "replace" || verdict == "good" {
            verdict = v;
        }
    };
    let flags = [
        (0x01, "available spare below its threshold"),
        (0x02, "temperature outside the safe range"),
        (0x04, "reliability degraded by media or internal errors"),
        (0x08, "the drive switched to read-only"),
        (0x10, "volatile memory backup failed"),
    ];
    for (bit, text) in flags {
        if h.critical_warning & bit != 0 {
            notes.push(format!("Critical warning: {text}."));
            worse(if bit == 0x02 { "watch" } else { "replace" });
        }
    }
    if h.spare_threshold > 0 && h.available_spare < h.spare_threshold {
        notes.push(format!(
            "Spare blocks at {}% (threshold {}%).",
            h.available_spare, h.spare_threshold
        ));
        worse("replace");
    }
    match h.percentage_used {
        p if p >= 100 => {
            notes.push(format!(
                "{p}% of the rated endurance used: past its rated life."
            ));
            worse("replace");
        }
        p if p >= 80 => {
            notes.push(format!("{p}% of the rated endurance used."));
            worse("watch");
        }
        _ => {}
    }
    if h.media_errors > 0 {
        notes.push(format!(
            "{} media/data integrity error(s) recorded.",
            h.media_errors
        ));
        worse("watch");
    }
    (verdict, notes)
}

pub fn from_raw(id: u64, name: String, status: i32, h: &RawNvmeHealth) -> Health {
    let status_text = match status {
        0 => "ok",
        1 => "unsupported",
        2 => "not permitted",
        _ => "unavailable",
    };
    let ok = status == 0;
    let (verdict, notes) = if ok {
        let (v, n) = assess(h);
        (Some(v), n)
    } else {
        (None, vec![])
    };
    let some = |v: u64| ok.then_some(v);
    Health {
        id: id.to_string(),
        name,
        status: status_text,
        verdict,
        percentage_used: ok.then_some(h.percentage_used),
        available_spare: ok.then_some(h.available_spare),
        spare_threshold: ok.then_some(h.spare_threshold),
        written_bytes: some(h.data_units_written.saturating_mul(DATA_UNIT)),
        read_bytes: some(h.data_units_read.saturating_mul(DATA_UNIT)),
        power_cycles: some(h.power_cycles),
        power_on_hours: some(h.power_on_hours),
        unsafe_shutdowns: some(h.unsafe_shutdowns),
        media_errors: some(h.media_errors),
        error_log_entries: some(h.error_log_entries),
        temperature_c: (ok && h.kelvin > 0).then_some(h.kelvin as f64 - 273.15),
        notes,
    }
}

/// Every physical disk the system lists, with its SMART health when it has NVMe SMART.
pub fn read() -> Vec<Health> {
    let mut raw: Vec<RawDisk> = (0..128).map(|_| unsafe { std::mem::zeroed() }).collect();
    let n = unsafe { os_disks(raw.as_mut_ptr(), 128) };
    raw.into_iter()
        .take(n.max(0) as usize)
        .map(|d| {
            let mut h = RawNvmeHealth::default();
            let status = unsafe { os_nvme_health(d.id, &mut h) };
            from_raw(d.id, string(&d.name), status, &h)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verdicts_from_the_log_page() {
        let healthy = RawNvmeHealth {
            available_spare: 100,
            spare_threshold: 99,
            percentage_used: 3,
            data_units_written: 40_000_000,
            power_on_hours: 1200,
            kelvin: 310,
            ..Default::default()
        };
        assert_eq!(assess(&healthy), ("good", vec![]));
        let h = from_raw(7, "APPLE SSD".into(), 0, &healthy);
        assert_eq!(h.written_bytes, Some(40_000_000 * 512_000), "20.48 TB");
        assert!((h.temperature_c.unwrap() - 36.85).abs() < 1e-9);

        let worn = RawNvmeHealth {
            percentage_used: 85,
            media_errors: 2,
            ..healthy
        };
        let (v, notes) = assess(&worn);
        assert_eq!(v, "watch");
        assert_eq!(notes.len(), 2);

        let failing = RawNvmeHealth {
            critical_warning: 0x08 | 0x02,
            available_spare: 5,
            spare_threshold: 10,
            percentage_used: 120,
            ..healthy
        };
        let (v, notes) = assess(&failing);
        assert_eq!(v, "replace");
        assert!(notes[0].contains("Critical warning"), "{notes:?}");
        assert!(notes.iter().any(|n| n.contains("past its rated life")));

        let usb = from_raw(9, "Kingston via USB".into(), 1, &RawNvmeHealth::default());
        assert_eq!(
            (usb.status, usb.verdict, usb.percentage_used),
            ("unsupported", None, None)
        );
    }
}
