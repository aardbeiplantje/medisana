# medisana.pl

BLE controller for **Medisana BS430** body composition scale over Linux BlueZ.

## Features

- **Weight measurement**: Connect and read weight when user steps on scale
- **Battery level**: Check device battery percentage at any time
- **No authentication**: Works with standard GATT services (no PIN required)
- **Notification-based**: Listens for scale measurements via BLE notifications
- **Linux native**: Pure Perl using raw `AF_BLUETOOTH`/`BTPROTO_L2CAP` sockets (no external dependencies)

## Prerequisites

- Linux system with BlueZ kernel support
- Perl 5 with core modules only (`Getopt::Long`, `Fcntl`, `Socket`, `Errno`)
- Bluetooth adapter and Medisana BS430 scale
- Scale must be in range and powered on

## Installation

```bash
chmod +x medisana.pl
```

## Usage

Basic syntax:
```bash
./medisana.pl -d AA:BB:CC:DD:EE:FF [actions] [options]
```

### Actions

| Action | Purpose |
|--------|---------|
| `--measure` | Wait for weight measurement (user steps on scale, default enabled) |
| `--battery` | Show battery level percentage (default enabled) |

### Required Options

| Option | Description |
|--------|-------------|
| `-d`, `--device ADDR` | BLE MAC address of the scale (required) |

### Optional Options

| Option | Default | Description |
|--------|---------|-------------|
| `--addr-type TYPE` | `public` | `public` or `random` address type |
| `--connect-timeout SEC` | `5` | Connection timeout in seconds |
| `--measure-timeout SEC` | `10` | Max seconds to wait for scale measurement |
| `-v`, `--debug` | off | Verbose debug output (repeat for more) |
| `-h`, `--help` | — | Show help |

### GATT UUID Overrides

For non-standard variants or testing:

```bash
./medisana.pl -d AA:BB:CC:DD:EE:FF \
  --service-uuid 181d \
  --weight-char-uuid 2a98 \
  --battery-char-uuid 2a19
```

## Examples

### Read weight (step on scale within 10 seconds)

```bash
./medisana.pl -d C7:AB:CD:12:34:56 --measure
```

Output:
```
Medisana BS430 BLE Scale Tool
=============================

Device: C7:AB:CD:12:34:56
Weight:  84.3 kg
```

### Check battery level

```bash
./medisana.pl -d C7:AB:CD:12:34:56 --battery
```

Output:
```
Medisana BS430 BLE Scale Tool
=============================

Device: C7:AB:CD:12:34:56
Battery: 87%
```

### Read both (default behavior)

```bash
./medisana.pl -d C7:AB:CD:12:34:56
```

### Debug mode (show all ATT/GATT operations)

```bash
./medisana.pl -d C7:AB:CD:12:34:56 -vv
```

## Protocol Reference

### GATT Services

**Body Composition Service (0x181D)** — Standard GATT service for body measurements

| Characteristic | UUID | Type | Notes |
|----------------|------|------|-------|
| Body Weight | `0x2A98` | Notify | uint16 in 0.1 kg units |
| Battery Level | `0x2A19` | Notify | uint8 percentage (0-100) |

### Measurement Notifications

The scale sends **ATT Handle Value Notifications** when user steps on it or battery is read:

- **Weight**: `[0x2A98 data]` — 2 bytes, uint16 little-endian, multiply by 0.1 for kg
  - Example: `0x0348` → 84.0 kg
- **Battery**: `[0x2A19 data]` — 1 byte, uint8 percentage
  - Example: `0x57` → 87%

## Connection Workflow

1. Open L2CAP socket to device (ATT fixed channel CID 4)
2. Exchange MTU (160 bytes for large responses)
3. Discover GATT service 0x181D and characteristics 0x2A98, 0x2A19
4. Subscribe to notifications (write CCCD 0x0001)
5. Wait for notifications or initiate reads
6. Disconnect and close socket

## Troubleshooting

### "BLE connection failed"

- Verify Bluetooth adapter: `hciconfig`
- Verify scale MAC address: `bluetoothctl scan on`
- Check scale is powered on and in range
- Try `--connect-timeout 10` for slower connections

### "Measurement handles not found"

- Scale may use custom GATT UUIDs (not standard 0x181D)
- Check with: `gatttool -b ADDR --primary`
- Run with `-v` to see discovered UUIDs
- Update `--service-uuid` and `--weight-char-uuid` as needed

### Measurement timeout (step on scale)

- Ensure you step on scale within the `--measure-timeout` window (default 10s)
- Some scales require calibration or specific weight ranges
- Check battery level — low battery may cause missed notifications

### "Unexpected ATT opcode" warnings

- Normal for multi-packet responses or stale notifications
- Script automatically retries; not an error

## Architecture

### Design

- **Object-oriented**: `Medisana::BS430` class encapsulates all BLE/GATT logic
- **Pure Perl**: No external BLE libraries; direct socket control for portability
- **ATT protocol**: Implements minimal ATT state machine (requests, responses, notifications)
- **Error handling**: Timeouts, connection failures, and malformed responses handled gracefully

### Code Structure

- **BLE connection**: `ble_connect()`, `ble_disconnect()`
- **GATT discovery**: `discover_handles()` finds service and characteristic handles
- **MTU negotiation**: `exchange_mtu()` for notification payload size
- **Subscription**: `subscribe_notify()` enables CCCD notifications
- **Measurement reads**: `read_weight()`, `read_battery()` wait for notifications
- **Generic ATT**: `att_request()` for synchronous request/response pairs

## Platform Support

Tested on:
- Linux (Debian/Ubuntu with BlueZ kernel)
- Perl 5.20+

Requires:
- Kernel BLE support (`AF_BLUETOOTH` socket family)
- BlueZ userspace tools (optional, for `bluetoothctl` debugging)

## Performance

- **Connection**: ~1-2 seconds
- **Weight read**: ~3-10 seconds (depends on user stepping on scale)
- **Battery read**: <1 second
- **Memory**: <10 MB
- **MTU**: Configurable, default 160 bytes

## License

See LICENSE file.
