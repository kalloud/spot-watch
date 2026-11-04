# Installs a signed .app on a USB-connected iOS device through macOS's
# MobileDevice framework: the install calls Xcode's legacy device stack makes.
# Needed because Xcode 27 can't install on iOS 15 and devicectl handles only
# iOS 17+ (see IOS_PLAN.md).
#
#   python3 -I install.py --list               UDIDs of USB-connected devices
#   python3 -I install.py App.app              install on the only connected device
#   python3 -I install.py --udid UDID App.app
#
# Read-only apart from the install itself. Uses only the system's Python and
# frameworks.
import ctypes
import ctypes.util
import sys
from ctypes import CFUNCTYPE, POINTER, Structure, c_bool, c_char_p, c_double, c_int, c_long, c_uint, c_void_p

MD = ctypes.CDLL("/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice")
CF = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
UTF8 = 0x08000100

CF.CFStringCreateWithCString.restype = c_void_p
CF.CFStringCreateWithCString.argtypes = [c_void_p, c_char_p, c_uint]
CF.CFStringGetCString.argtypes = [c_void_p, c_char_p, c_long, c_uint]
CF.CFURLCreateWithFileSystemPath.restype = c_void_p
CF.CFURLCreateWithFileSystemPath.argtypes = [c_void_p, c_void_p, c_int, c_bool]
CF.CFDictionaryCreate.restype = c_void_p
CF.CFDictionaryCreate.argtypes = [c_void_p, POINTER(c_void_p), POINTER(c_void_p), c_long, c_void_p, c_void_p]
CF.CFDictionaryGetValue.restype = c_void_p
CF.CFDictionaryGetValue.argtypes = [c_void_p, c_void_p]
CF.CFNumberGetValue.argtypes = [c_void_p, c_int, c_void_p]
CF.CFRunLoopRunInMode.argtypes = [c_void_p, c_double, c_bool]

for name in ("AMDeviceConnect", "AMDeviceDisconnect", "AMDeviceIsPaired", "AMDeviceValidatePairing",
             "AMDeviceStartSession", "AMDeviceStopSession", "AMDeviceGetInterfaceType"):
    getattr(MD, name).argtypes = [c_void_p]
    getattr(MD, name).restype = c_int
MD.AMDeviceCopyDeviceIdentifier.restype = c_void_p
MD.AMDeviceCopyDeviceIdentifier.argtypes = [c_void_p]
MD.AMDeviceCopyValue.restype = c_void_p
MD.AMDeviceCopyValue.argtypes = [c_void_p, c_void_p, c_void_p]
PROGRESS = CFUNCTYPE(c_int, c_void_p, c_int)
for name in ("AMDeviceSecureTransferPath", "AMDeviceSecureInstallApplication"):
    getattr(MD, name).argtypes = [c_int, c_void_p, c_void_p, c_void_p, PROGRESS, c_int]
    getattr(MD, name).restype = c_int


def cfstr(s):
    return CF.CFStringCreateWithCString(None, s.encode(), UTF8)


def pystr(ref):
    if not ref:
        return None
    buf = ctypes.create_string_buffer(1024)
    return buf.value.decode() if CF.CFStringGetCString(ref, buf, 1024, UTF8) else None


def check(rc, what):
    if rc != 0:
        sys.exit(f"Failed to {what}: 0x{rc & 0xffffffff:08x}")


class Notification(Structure):
    _fields_ = [("device", c_void_p), ("msg", c_uint)]


def usb_devices(wait_s=3.0):
    """{udid: device} for devices on USB, collected for `wait_s` seconds."""
    found = {}

    def on_event(info, _):
        d = info.contents.device
        if info.contents.msg == 1 and MD.AMDeviceGetInterfaceType(d) == 1:   # connected, USB
            found[pystr(MD.AMDeviceCopyDeviceIdentifier(d))] = d

    usb_devices.callback = CFUNCTYPE(None, POINTER(Notification), c_void_p)(on_event)   # keep alive
    handle = c_void_p()
    MD.AMDeviceNotificationSubscribe(usb_devices.callback, 0, 0, None, ctypes.byref(handle))
    CF.CFRunLoopRunInMode(c_void_p.in_dll(CF, "kCFRunLoopDefaultMode"), wait_s, False)
    return found


def start_session(dev):
    check(MD.AMDeviceConnect(dev), "connect")
    if not MD.AMDeviceIsPaired(dev):
        sys.exit("The device isn't paired with this Mac: unlock it and tap Trust.")
    check(MD.AMDeviceValidatePairing(dev), "validate pairing")
    check(MD.AMDeviceStartSession(dev), "start a session")


def end_session(dev):
    MD.AMDeviceStopSession(dev)
    MD.AMDeviceDisconnect(dev)


def progress(stage):
    last = [None]

    def on_progress(d, _):
        status = pystr(CF.CFDictionaryGetValue(d, cfstr("Status")))
        if status != last[0]:
            print(f"  {stage}: {status}", flush=True)
            last[0] = status
        return 0

    return PROGRESS(on_progress)


def install(dev, app):
    start_session(dev)
    name = pystr(MD.AMDeviceCopyValue(dev, None, cfstr("DeviceName")))
    version = pystr(MD.AMDeviceCopyValue(dev, None, cfstr("ProductVersion")))
    print(f"Installing on {name} (iOS {version})", flush=True)
    end_session(dev)

    url = CF.CFURLCreateWithFileSystemPath(None, cfstr(app), 0, True)     # POSIX path, directory
    keys = (c_void_p * 1)(cfstr("PackageType"))
    values = (c_void_p * 1)(cfstr("Developer"))
    options = CF.CFDictionaryCreate(None, keys, values, 1,
                                    ctypes.addressof(ctypes.c_char.in_dll(CF, "kCFTypeDictionaryKeyCallBacks")),
                                    ctypes.addressof(ctypes.c_char.in_dll(CF, "kCFTypeDictionaryValueCallBacks")))
    transfer, installing = progress("copy"), progress("install")
    check(MD.AMDeviceSecureTransferPath(0, dev, url, options, transfer, 0), "copy the app")
    start_session(dev)
    check(MD.AMDeviceSecureInstallApplication(0, dev, url, options, installing, 0), "install the app")
    end_session(dev)
    print("Installed", app)


def main(argv):
    devices = usb_devices()
    if argv[:1] == ["--list"]:
        print("\n".join(devices))
        return
    udid = None
    if argv[:1] == ["--udid"]:
        udid, argv = argv[1], argv[2:]
    if len(argv) != 1:
        sys.exit(__doc__ or "usage: install.py [--list | [--udid UDID] App.app]")
    if udid is None:
        if len(devices) != 1:
            sys.exit(f"Found {len(devices)} USB devices; pass --udid (see --list).")
        udid = next(iter(devices))
    if udid not in devices:
        sys.exit(f"Device {udid} isn't connected over USB.")
    install(devices[udid], argv[0])


if __name__ == "__main__":
    main(sys.argv[1:])
