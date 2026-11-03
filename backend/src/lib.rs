//! StreamCam's UVC control engine and CLI. Camera-independent logic is tested
//! against a fake transport; the real transport only uses endpoint-zero IO.
use fs2::FileExt;
use nusb::transfer::{ControlIn, ControlOut, ControlType, Recipient, TransferError};
use nusb::{Device, MaybeFuture};
use serde::Serialize;
use std::collections::BTreeMap;
use std::error::Error;
use std::fs::{self, OpenOptions};
use std::time::Duration;

type Result<T> = std::result::Result<T, Box<dyn Error>>;

#[derive(Clone, Copy)]
struct Spec {
    name: &'static str,
    bit: usize,
    selector: u8,
    length: u16,
    kind: Kind,
}

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Scalar,
    Boolean,
    PanTilt,
}

const CAMERA: &[Spec] = &[
    Spec {
        name: "zoom",
        bit: 9,
        selector: 0x0b,
        length: 2,
        kind: Kind::Scalar,
    },
    Spec {
        name: "pan",
        bit: 11,
        selector: 0x0d,
        length: 8,
        kind: Kind::PanTilt,
    },
];
const PROCESSING: &[Spec] = &[
    Spec {
        name: "saturation",
        bit: 3,
        selector: 7,
        length: 2,
        kind: Kind::Scalar,
    },
    Spec {
        name: "white-balance",
        bit: 6,
        selector: 0x0a,
        length: 2,
        kind: Kind::Scalar,
    },
    Spec {
        name: "auto-white-balance",
        bit: 12,
        selector: 0x0b,
        length: 1,
        kind: Kind::Boolean,
    },
];

#[derive(Clone, Copy)]
struct Control {
    interface: u8,
    unit: u8,
    spec: Spec,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct State {
    value: i32,
    min: i32,
    max: i32,
    step: i32,
    default_value: Option<i32>,
    writable: bool,
    disabled_by_auto: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Status {
    protocol_version: u8,
    device: String,
    device_id: String,
    controls: BTreeMap<String, State>,
}

trait Transport {
    fn read(&self, control: Control, request: u8, length: u16) -> Result<Vec<u8>>;
    fn write(&self, control: Control, bytes: &[u8]) -> Result<()>;
}

impl Transport for Device {
    fn read(&self, c: Control, request: u8, length: u16) -> Result<Vec<u8>> {
        Ok(self
            .control_in(
                ControlIn {
                    control_type: ControlType::Class,
                    recipient: Recipient::Interface,
                    request,
                    value: u16::from(c.spec.selector) << 8,
                    index: (u16::from(c.unit) << 8) | u16::from(c.interface),
                    length,
                },
                Duration::from_millis(700),
            )
            .wait()?)
    }

    fn write(&self, c: Control, bytes: &[u8]) -> Result<()> {
        self.control_out(
            ControlOut {
                control_type: ControlType::Class,
                recipient: Recipient::Interface,
                request: 0x01,
                value: u16::from(c.spec.selector) << 8,
                index: (u16::from(c.unit) << 8) | u16::from(c.interface),
                data: bytes,
            },
            Duration::from_millis(700),
        )
        .wait()?;
        Ok(())
    }
}

struct Camera<T: Transport = Device> {
    device: T,
    controls: BTreeMap<String, Control>,
    name: String,
    device_id: String,
}

fn check_device_id(actual: &str, expected: Option<&str>) -> Result<()> {
    if expected.is_some_and(|expected| expected != actual) {
        return Err(
            "Camera connection changed. Refresh the panel before adjusting settings.".into(),
        );
    }
    Ok(())
}

fn insert_descriptor(
    controls: &mut BTreeMap<String, Control>,
    interface: u8,
    b: &[u8],
) -> Result<()> {
    if b.get(1) != Some(&0x24) {
        return Ok(());
    }
    let (bits, specs) = match b.get(2) {
        Some(2) if b.len() >= 15 && b[4..6] == [1, 2] => (
            b.get(15..15 + usize::from(b[14]))
                .ok_or("Malformed camera-terminal bitmap")?,
            CAMERA,
        ),
        Some(5) if b.len() >= 8 => (
            b.get(8..8 + usize::from(b[7]))
                .ok_or("Malformed processing-unit bitmap")?,
            PROCESSING,
        ),
        _ => return Ok(()),
    };
    for &spec in specs {
        if bits
            .get(spec.bit / 8)
            .is_none_or(|byte| byte & (1 << (spec.bit % 8)) == 0)
        {
            continue;
        }
        let c = Control {
            interface,
            unit: b[3],
            spec,
        };
        for name in if spec.kind == Kind::PanTilt {
            vec!["pan", "tilt"]
        } else {
            vec![spec.name]
        } {
            if controls.insert(name.into(), c).is_some() {
                return Err(format!("Ambiguous {name} control").into());
            }
        }
    }
    Ok(())
}

impl Camera<Device> {
    fn open(expected_id: Option<&str>) -> Result<Self> {
        let devices: Vec<_> = nusb::list_devices()
            .wait()?
            .filter(|d| d.vendor_id() == 0x046d && d.product_id() == 0x0893)
            .collect();
        let info =
            match devices.as_slice() {
                [] => {
                    return Err(
                        "No supported StreamCam connected. StreamCam Controls supports 046d:0893."
                            .into(),
                    )
                }
                [info] => info,
                _ => return Err(
                    "Multiple StreamCams connected. Connect only the camera you want to control."
                        .into(),
                ),
            };
        let device_id = format!("{:?}", info.id());
        check_device_id(&device_id, expected_id)?;
        let name = info
            .product_string()
            .unwrap_or("Logitech StreamCam")
            .to_owned();
        let device = info.open().wait()?;
        let mut controls = BTreeMap::new();
        for interface in device
            .active_configuration()?
            .interface_alt_settings()
            .filter(|i| i.class() == 0x0e && i.subclass() == 1 && i.alternate_setting() == 0)
        {
            for descriptor in interface.descriptors() {
                insert_descriptor(
                    &mut controls,
                    interface.interface_number(),
                    descriptor.as_bytes(),
                )?;
            }
        }
        Ok(Self {
            device,
            controls,
            name,
            device_id,
        })
    }
}

impl<T: Transport> Camera<T> {
    fn control(&self, name: &str) -> Result<Control> {
        self.controls
            .get(name)
            .copied()
            .ok_or_else(|| format!("Unsupported control: {name}").into())
    }

    fn get(&self, c: Control, request: u8, length: u16) -> Result<Vec<u8>> {
        let bytes = self.device.read(c, request, length)?;
        if bytes.len() != usize::from(length) {
            return Err("Unexpected camera response length".into());
        }
        Ok(bytes)
    }

    fn value(&self, name: &str, request: u8) -> Result<i32> {
        let c = self.control(name)?;
        let bytes = self.get(c, request, c.spec.length)?;
        Ok(match c.spec.kind {
            Kind::Boolean => i32::from(bytes[0]),
            Kind::Scalar => i32::from(u16::from_le_bytes(bytes[..2].try_into()?)),
            Kind::PanTilt => {
                let offset = if name == "tilt" { 4 } else { 0 };
                i32::from_le_bytes(bytes[offset..offset + 4].try_into()?)
            }
        })
    }

    fn state(&self, name: &str) -> Result<State> {
        let c = self.control(name)?;
        let info = self.get(c, 0x86, 1)?[0];
        if info & 1 == 0 {
            return Err(format!("{name} is not readable").into());
        }
        let (min, max, step) = if c.spec.kind == Kind::Boolean {
            (0, 1, 1)
        } else {
            (
                self.value(name, 0x82)?,
                self.value(name, 0x83)?,
                self.value(name, 0x84)?,
            )
        };
        let default_value = match self.value(name, 0x87) {
            Ok(value) => Some(value),
            Err(error) if error.downcast_ref::<TransferError>() == Some(&TransferError::Stall) => {
                None
            }
            Err(error) => return Err(error),
        };
        Ok(State {
            value: self.value(name, 0x81)?,
            min,
            max,
            step,
            default_value,
            writable: info & 2 != 0,
            disabled_by_auto: info & 4 != 0,
        })
    }

    fn status(&self) -> Result<Status> {
        let mut controls = BTreeMap::new();
        for name in self.controls.keys() {
            controls.insert(name.clone(), self.state(name)?);
        }
        Ok(Status {
            protocol_version: 1,
            device: self.name.clone(),
            device_id: self.device_id.clone(),
            controls,
        })
    }

    fn validate(&self, name: &str, value: i32) -> Result<()> {
        let s = self.state(name)?;
        if !s.writable
            || s.step <= 0
            || value < s.min
            || value > s.max
            || (i64::from(value) - i64::from(s.min)) % i64::from(s.step) != 0
        {
            return Err(format!(
                "Invalid {name}={value}; supported range {} to {}, step {}",
                s.min, s.max, s.step
            )
            .into());
        }
        Ok(())
    }

    fn write(&self, name: &str, value: i32) -> Result<()> {
        self.validate(name, value)?;
        let c = self.control(name)?;
        let info = self.get(c, 0x86, 1)?[0];
        if info & 4 != 0 {
            return Err(format!("{name} is disabled by automatic mode").into());
        }
        let data = match c.spec.kind {
            Kind::Boolean => vec![u8::try_from(value)?],
            Kind::Scalar => u16::try_from(value)?.to_le_bytes().to_vec(),
            Kind::PanTilt => {
                let mut bytes = self.get(c, 0x81, 8)?;
                let offset = if name == "tilt" { 4 } else { 0 };
                bytes[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
                bytes
            }
        };
        self.device.write(c, &data)?;
        if self.value(name, 0x81)? != value {
            return Err(format!("Camera did not retain {name}={value}").into());
        }
        Ok(())
    }

    fn apply(&self, values: &BTreeMap<String, i32>) -> Result<()> {
        // Validate the entire request before the first write. Camera writes
        // are still not atomic; a disconnect can cause a partially applied batch.
        for (name, &value) in values {
            self.validate(name, value)?;
        }
        let temperature = values.get("white-balance");
        let final_auto = values.get("auto-white-balance").copied();
        let original_auto = if temperature.is_some() {
            Some(self.value("auto-white-balance", 0x81)?)
        } else {
            None
        };
        let changes = (|| -> Result<()> {
            if temperature.is_some() {
                self.write("auto-white-balance", 0)?;
            }
            for name in ["zoom", "pan", "tilt", "saturation", "white-balance"] {
                if let Some(&value) = values.get(name) {
                    self.write(name, value)?;
                }
            }
            if let Some(auto) = final_auto {
                self.write("auto-white-balance", auto)?;
            }
            Ok(())
        })();
        // If a batch fails, still restore the previous auto mode when changed.
        if let Err(error) = changes {
            if let Some(auto) = original_auto {
                if let Err(restore) = self.write("auto-white-balance", auto) {
                    return Err(format!(
                        "Partial apply: {error}; restoring automatic mode also failed: {restore}"
                    )
                    .into());
                }
            }
            return Err(
                format!("Partial apply: {error}; read current values before retrying").into(),
            );
        }
        Ok(())
    }

    fn defaults(&self) -> Result<()> {
        let mut values: BTreeMap<_, _> = self
            .status()?
            .controls
            .into_iter()
            .filter(|(_, state)| state.writable)
            .filter_map(|(name, state)| state.default_value.map(|value| (name, value)))
            .collect();
        if values.is_empty() {
            return Err("The camera provides no writable defaults for these controls.".into());
        }
        // If the camera does not supply an auto-mode default, preserve the
        // current mode when resetting its manual temperature.
        if values.contains_key("white-balance") && !values.contains_key("auto-white-balance") {
            values.insert(
                "auto-white-balance".into(),
                self.value("auto-white-balance", 0x81)?,
            );
        }
        self.apply(&values)
    }
}

#[derive(Debug, PartialEq)]
enum Command {
    Status,
    Set(String, i32),
    Apply(BTreeMap<String, i32>),
    Defaults,
    Help,
    Version,
}

fn parse(args: &[String]) -> Result<(Option<String>, Command)> {
    let (expected, args) = if args.first().is_some_and(|s| s == "--device-id") {
        (
            Some(
                args.get(1)
                    .filter(|s| !s.is_empty())
                    .ok_or("Missing device ID")?
                    .clone(),
            ),
            &args[2..],
        )
    } else {
        (None, args)
    };
    let command =
        match args
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>()
            .as_slice()
        {
            [] | ["status"] => Command::Status,
            ["--help"] | ["-h"] => Command::Help,
            ["--version"] | ["-V"] => Command::Version,
            ["set", name, value] => Command::Set((*name).into(), value.parse()?),
            ["apply", json] => Command::Apply(serde_json::from_str(json)?),
            ["defaults"] => Command::Defaults,
            _ => return Err(
                "Usage: streamcam [--device-id ID] status | set NAME VALUE | apply JSON | defaults"
                    .into(),
            ),
        };
    Ok((expected, command))
}

pub fn run() -> Result<()> {
    let (expected, command) = parse(&std::env::args().skip(1).collect::<Vec<_>>())?;
    match command {
        Command::Version => {
            println!("streamcam {}", env!("CARGO_PKG_VERSION"));
            return Ok(());
        }
        Command::Help => {
            println!("StreamCam Controls\nUsage: streamcam [--device-id ID] [status | set NAME VALUE | apply JSON | defaults]\nControls: zoom, pan, tilt, saturation, white-balance, auto-white-balance\nValues use camera units; pan/tilt use arc-seconds, white balance uses Kelvin.\nSetting white-balance switches to manual mode. No command means status.");
            return Ok(());
        }
        _ => {}
    }
    let home = std::env::var_os("HOME").ok_or("HOME is unset")?;
    let lock_dir =
        std::path::PathBuf::from(home).join("Library/Caches/com.dreamorosi.streamcam-controls");
    fs::create_dir_all(&lock_dir)?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(lock_dir.join("controls.lock"))?;
    lock.try_lock_exclusive()
        .map_err(|_| "Another StreamCam command is running. Try again.")?;
    let camera = Camera::open(expected.as_deref())?;
    match command {
        Command::Status => {}
        Command::Set(name, value) => {
            let mut values = BTreeMap::new();
            if name == "white-balance" {
                values.insert("auto-white-balance".into(), 0);
            }
            values.insert(name, value);
            camera.apply(&values)?;
        }
        Command::Apply(values) => camera.apply(&values)?,
        Command::Defaults => camera.defaults()?,
        Command::Help | Command::Version => unreachable!(),
    }
    println!("{}", serde_json::to_string(&camera.status()?)?);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::{Cell, RefCell};
    use std::collections::BTreeSet;

    #[derive(Clone)]
    struct Value {
        current: i32,
        min: i32,
        max: i32,
        step: i32,
        default: i32,
    }

    struct Fake {
        values: RefCell<BTreeMap<String, Value>>,
        writes: RefCell<Vec<(String, i32)>>,
        unsupported_defaults: BTreeSet<String>,
        fail_write: RefCell<Option<(String, i32)>>,
        bad_auto_verification: Cell<bool>,
        bad_readback: Cell<bool>,
        malformed: bool,
        default_fault: bool,
    }

    impl Fake {
        fn new() -> Self {
            let values = [
                ("zoom", 138, 100, 400, 1, 100),
                ("pan", 3600, -36000, 36000, 3600, 0),
                ("tilt", -7200, -36000, 36000, 3600, 0),
                ("saturation", 180, 0, 255, 1, 128),
                ("white-balance", 4447, 2000, 7500, 1, 4000),
                ("auto-white-balance", 1, 0, 1, 1, 1),
            ]
            .into_iter()
            .map(|(name, current, min, max, step, default)| {
                (
                    name.into(),
                    Value {
                        current,
                        min,
                        max,
                        step,
                        default,
                    },
                )
            })
            .collect();
            Self {
                values: RefCell::new(values),
                writes: RefCell::new(vec![]),
                unsupported_defaults: BTreeSet::new(),
                fail_write: RefCell::new(None),
                bad_auto_verification: Cell::new(false),
                bad_readback: Cell::new(false),
                malformed: false,
                default_fault: false,
            }
        }

        fn selected(&self, name: &str, request: u8) -> i32 {
            let values = self.values.borrow();
            let v = &values[name];
            match request {
                0x81 => v.current,
                0x82 => v.min,
                0x83 => v.max,
                0x84 => v.step,
                0x87 => v.default,
                _ => panic!("unexpected request"),
            }
        }
    }

    impl Transport for Fake {
        fn read(&self, c: Control, request: u8, _length: u16) -> Result<Vec<u8>> {
            if self.malformed {
                return Ok(vec![]);
            }
            if request == 0x86 {
                let disabled = c.spec.name == "white-balance"
                    && self.selected("auto-white-balance", 0x81) == 1;
                return Ok(vec![if disabled { 7 } else { 3 }]);
            }
            if request == 0x87 {
                if self.default_fault {
                    return Err(TransferError::Disconnected.into());
                }
                if self.unsupported_defaults.contains(c.spec.name) {
                    return Err(TransferError::Stall.into());
                }
            }
            if c.spec.name == "auto-white-balance"
                && request == 0x81
                && self.bad_readback.replace(false)
            {
                return Ok(vec![1]);
            }
            if c.spec.kind == Kind::PanTilt {
                let mut bytes = self.selected("pan", request).to_le_bytes().to_vec();
                bytes.extend_from_slice(&self.selected("tilt", request).to_le_bytes());
                return Ok(bytes);
            }
            let v = self.selected(c.spec.name, request);
            Ok(if c.spec.kind == Kind::Boolean {
                vec![v as u8]
            } else {
                (v as u16).to_le_bytes().to_vec()
            })
        }

        fn write(&self, c: Control, bytes: &[u8]) -> Result<()> {
            let v = match c.spec.kind {
                Kind::Boolean => i32::from(bytes[0]),
                Kind::Scalar => i32::from(u16::from_le_bytes(bytes.try_into()?)),
                Kind::PanTilt => i32::from_le_bytes(bytes[..4].try_into()?),
            };
            self.writes.borrow_mut().push((c.spec.name.into(), v));
            if self.fail_write.borrow().as_ref() == Some(&(c.spec.name.into(), v)) {
                self.fail_write.borrow_mut().take();
                return Err("simulated USB write failure".into());
            }
            self.values
                .borrow_mut()
                .get_mut(c.spec.name)
                .unwrap()
                .current = v;
            if c.spec.kind == Kind::PanTilt {
                self.values.borrow_mut().get_mut("tilt").unwrap().current =
                    i32::from_le_bytes(bytes[4..].try_into()?);
            }
            if c.spec.name == "auto-white-balance"
                && v == 0
                && self.bad_auto_verification.replace(false)
            {
                self.bad_readback.set(true);
            }
            Ok(())
        }
    }

    fn camera() -> Camera<Fake> {
        let mut controls = BTreeMap::new();
        insert_descriptor(
            &mut controls,
            0,
            &[
                18, 0x24, 2, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0x2e, 0x2a, 2,
            ],
        )
        .unwrap();
        insert_descriptor(
            &mut controls,
            0,
            &[11, 0x24, 5, 3, 1, 0, 0x40, 2, 0x5b, 0x17, 0],
        )
        .unwrap();
        Camera {
            device: Fake::new(),
            controls,
            name: "Fake StreamCam".into(),
            device_id: "connection-1".into(),
        }
    }

    fn values(items: &[(&str, i32)]) -> BTreeMap<String, i32> {
        items
            .iter()
            .map(|(name, value)| ((*name).into(), *value))
            .collect()
    }

    #[test]
    fn descriptors_supply_unit_ids_and_shared_pan_tilt() {
        let c = camera();
        assert_eq!(c.control("zoom").unwrap().unit, 1);
        assert_eq!(c.control("saturation").unwrap().unit, 3);
        assert_eq!(c.control("tilt").unwrap().spec.selector, 0x0d);
        assert!(c.control("contrast").is_err());
    }

    #[test]
    fn rejects_malformed_and_ambiguous_descriptors() {
        let mut controls = BTreeMap::new();
        assert!(insert_descriptor(&mut controls, 0, &[9, 0x24, 5, 3, 1, 0, 0, 4, 1]).is_err());
        let descriptor = [10, 0x24, 5, 3, 1, 0, 0, 1, 8, 0];
        insert_descriptor(&mut controls, 0, &descriptor).unwrap();
        assert!(insert_descriptor(&mut controls, 0, &descriptor).is_err());
    }

    #[test]
    fn validates_entire_batch_before_writing() {
        let c = camera();
        assert!(c
            .apply(&values(&[("zoom", 200), ("saturation", 256)]))
            .is_err());
        assert!(c.apply(&values(&[("unknown", 1)])).is_err());
        assert!(c.apply(&values(&[("pan", 100)])).is_err());
        assert!(c.apply(&values(&[("auto-white-balance", 2)])).is_err());
        assert!(c.device.writes.borrow().is_empty());
    }

    #[test]
    fn validation_handles_signed_extremes_without_overflow() {
        let c = camera();
        {
            let mut v = c.device.values.borrow_mut();
            let pan = v.get_mut("pan").unwrap();
            pan.min = i32::MIN;
            pan.max = i32::MAX;
            pan.step = 1;
        }
        c.validate("pan", i32::MAX).unwrap();
    }

    #[test]
    fn single_axis_writes_preserve_the_other_axis() {
        let c = camera();
        c.write("pan", 18000).unwrap();
        assert_eq!(c.value("tilt", 0x81).unwrap(), -7200);
        c.write("tilt", 3600).unwrap();
        assert_eq!(c.value("pan", 0x81).unwrap(), 18000);
        assert_eq!(c.value("tilt", 0x81).unwrap(), 3600);
    }

    #[test]
    fn manual_white_balance_changes_mode_before_temperature() {
        let c = camera();
        c.apply(&values(&[
            ("white-balance", 4500),
            ("auto-white-balance", 0),
        ]))
        .unwrap();
        assert_eq!(
            c.device.writes.borrow()[0],
            ("auto-white-balance".into(), 0)
        );
        assert_eq!(c.device.writes.borrow()[1], ("white-balance".into(), 4500));
        assert_eq!(c.value("auto-white-balance", 0x81).unwrap(), 0);
    }

    #[test]
    fn defaults_restore_reported_values_and_enable_auto_last() {
        let c = camera();
        c.defaults().unwrap();
        let writes = c.device.writes.borrow();
        assert_eq!(writes.last().unwrap(), &("auto-white-balance".into(), 1));
        assert_eq!(c.value("zoom", 0x81).unwrap(), 100);
        assert_eq!(c.value("pan", 0x81).unwrap(), 0);
        assert_eq!(c.value("tilt", 0x81).unwrap(), 0);
        assert_eq!(c.value("saturation", 0x81).unwrap(), 128);
        assert_eq!(c.value("white-balance", 0x81).unwrap(), 4000);
    }

    #[test]
    fn unsupported_defaults_are_not_guessed() {
        let mut c = camera();
        c.device.unsupported_defaults.insert("saturation".into());
        c.defaults().unwrap();
        assert_eq!(c.value("saturation", 0x81).unwrap(), 180);
    }

    #[test]
    fn missing_auto_default_preserves_current_manual_mode() {
        let mut c = camera();
        c.device
            .unsupported_defaults
            .insert("auto-white-balance".into());
        c.device
            .values
            .borrow_mut()
            .get_mut("auto-white-balance")
            .unwrap()
            .current = 0;
        c.defaults().unwrap();
        assert_eq!(c.value("auto-white-balance", 0x81).unwrap(), 0);
    }

    #[test]
    fn absence_of_all_defaults_is_reported_without_writes() {
        let mut c = camera();
        c.device.unsupported_defaults = c.device.values.borrow().keys().cloned().collect();
        assert!(c.defaults().is_err());
        assert!(c.device.writes.borrow().is_empty());
    }

    #[test]
    fn final_mode_write_failure_restores_original_auto_mode() {
        let c = camera();
        *c.device.fail_write.borrow_mut() = Some(("auto-white-balance".into(), 1));
        assert!(c
            .apply(&values(&[
                ("white-balance", 4500),
                ("auto-white-balance", 1)
            ]))
            .is_err());
        assert_eq!(c.value("auto-white-balance", 0x81).unwrap(), 1);
    }

    #[test]
    fn write_failure_restores_auto_mode() {
        let c = camera();
        *c.device.fail_write.borrow_mut() = Some(("white-balance".into(), 4500));
        let error = c
            .apply(&values(&[
                ("white-balance", 4500),
                ("auto-white-balance", 0),
            ]))
            .unwrap_err();
        assert!(error.to_string().contains("Partial apply"));
        assert_eq!(c.value("auto-white-balance", 0x81).unwrap(), 1);
    }

    #[test]
    fn failed_mode_disable_verification_also_restores_auto() {
        let c = camera();
        c.device.bad_auto_verification.set(true);
        assert!(c.apply(&values(&[("white-balance", 4500)])).is_err());
        assert_eq!(c.value("auto-white-balance", 0x81).unwrap(), 1);
        assert_eq!(c.value("white-balance", 0x81).unwrap(), 4447);
    }

    #[test]
    fn malformed_and_disconnected_responses_are_not_hidden() {
        let mut c = camera();
        c.device.malformed = true;
        assert!(c.status().is_err());
        c.device.malformed = false;
        c.device.default_fault = true;
        assert!(c.status().is_err());
    }

    #[test]
    fn stale_device_identity_is_rejected() {
        assert!(check_device_id("new-connection", Some("old-connection")).is_err());
        assert!(check_device_id("current", Some("current")).is_ok());
        assert!(check_device_id("current", None).is_ok());
    }

    #[test]
    fn parses_commands_without_usb_access() {
        let args = |items: &[&str]| items.iter().map(|s| (*s).into()).collect::<Vec<_>>();
        assert_eq!(parse(&[]).unwrap().1, Command::Status);
        assert_eq!(
            parse(&args(&["set", "zoom", "200"])).unwrap().1,
            Command::Set("zoom".into(), 200)
        );
        assert_eq!(
            parse(&args(&["--device-id", "connection-1", "status"]))
                .unwrap()
                .0
                .as_deref(),
            Some("connection-1")
        );
        assert!(parse(&args(&["--device-id"])).is_err());
        assert!(parse(&args(&["apply", "{\"zoom\":1.5}"])).is_err());
        assert!(parse(&args(&["set", "zoom", "invalid"])).is_err());
        assert!(parse(&args(&["invalid"])).is_err());
    }
}
