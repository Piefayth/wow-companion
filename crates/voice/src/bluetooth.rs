//! The Bluetooth voice link's reconnect, as Sound settings' Connect does it.

use super::*;

/// Ask every active audio endpoint to reconnect its Bluetooth link, the way the
/// Sound control panel's "Connect" does: KSPROPERTY_ONESHOT_RECONNECT on the
/// endpoint's topology part. Endpoints that are not Bluetooth refuse it and are
/// skipped. Needs no admin. Returns how many accepted.
#[cfg(windows)]
pub(crate) fn reconnect_bluetooth_audio() -> usize {
    reconnect_bluetooth_audio_verbose(false)
}

#[cfg(windows)]
pub(crate) fn reconnect_bluetooth_audio_verbose(verbose: bool) -> usize {
    use windows::{
        Win32::{
            Media::{
                Audio::{eAll, IDeviceTopology, IMMDeviceEnumerator, MMDeviceEnumerator, DEVICE_STATE_ACTIVE},
                KernelStreaming::{
                    IKsControl, KSIDENTIFIER, KSIDENTIFIER_0, KSIDENTIFIER_0_0, KSPROPERTY_ONESHOT_RECONNECT,
                    KSPROPERTY_TYPE_GET, KSPROPSETID_BtAudio,
                },
            },
            System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED},
        },
    };
    let mut accepted = 0;
    unsafe {
        // already initialised on this thread is fine
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let Ok(enumerator) = CoCreateInstance::<_, IMMDeviceEnumerator>(&MMDeviceEnumerator, None, CLSCTX_ALL) else {
            return 0;
        };
        let Ok(devices) = enumerator.EnumAudioEndpoints(eAll, DEVICE_STATE_ACTIVE) else { return 0 };
        let count = devices.GetCount().unwrap_or(0);
        for index in 0..count {
            let attempt = || -> Result<(), String> {
                let step = |what: &str, err: windows::core::Error| format!("{what}: {err}");
                let device = devices.Item(index).map_err(|e| step("item", e))?;
                let topology: IDeviceTopology = device.Activate(CLSCTX_ALL, None).map_err(|e| step("topology", e))?;
                let connector = topology.GetConnector(0).map_err(|e| step("connector", e))?;
                // the device on the far side of the endpoint's connector is the
                // Bluetooth audio filter; IKsControl lives on it, not on its parts
                let filter_id = connector.GetDeviceIdConnectedTo().map_err(|e| step("filter id", e))?;
                let filter = enumerator
                    .GetDevice(windows::core::PCWSTR(filter_id.0))
                    .map_err(|e| step("filter", e))?;
                let control: IKsControl = filter.Activate(CLSCTX_ALL, None).map_err(|e| step("ks control", e))?;
                let property = KSIDENTIFIER {
                    Anonymous: KSIDENTIFIER_0 {
                        Anonymous: KSIDENTIFIER_0_0 {
                            Set: KSPROPSETID_BtAudio,
                            Id: KSPROPERTY_ONESHOT_RECONNECT.0 as u32,
                            Flags: KSPROPERTY_TYPE_GET,
                        },
                    },
                };
                let mut returned = 0u32;
                control
                    .KsProperty(
                        &property,
                        std::mem::size_of::<KSIDENTIFIER>() as u32,
                        std::ptr::null_mut(),
                        0,
                        &mut returned,
                    )
                    .map_err(|e| step("reconnect", e))
            };
            match attempt() {
                Ok(()) => accepted += 1,
                Err(why) if verbose => println!("  endpoint {index}: {why}"),
                Err(_) => {}
            }
        }
    }
    accepted
}

#[cfg(not(windows))]
pub(crate) fn reconnect_bluetooth_audio() -> usize {
    0
}

/// For testing the reconnect by hand: `wow-companion reconnect`.
pub fn reconnect() -> io::Result<()> {
    println!("reconnect accepted by {} endpoint(s)", reconnect_bluetooth_audio_verbose(true));
    Ok(())
}
