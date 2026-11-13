// Minimal repro: open NSPrintPanel and cancel it N times, print phys_footprint each time.
import AppKit

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

let n = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1])! : 10
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
print(String(format: "start  %.1f MB", footprintMB()))
for i in 1...n {
    autoreleasepool {
        // Dismiss the panel 1.5s after it appears via abortModal (the Preview run in README uses the real Cancel button).
        let t = Timer(timeInterval: 1.5, repeats: false) { _ in app.abortModal() }
        RunLoop.main.add(t, forMode: .modalPanel)
        let r = NSPrintPanel().runModal(with: NSPrintInfo.shared)
        _ = r
    }
    print(String(format: "%3d    %.1f MB", i, footprintMB()))
}
