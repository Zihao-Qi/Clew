import AppKit
import ClewDomain
import SwiftUI

/// An hour-and-minute picker whose text box fits its text. SwiftUI's DatePicker
/// uses NSDatePicker's intrinsic width, which is a few points short for "6:00 PM"
/// (the M touches the border), and a SwiftUI frame cannot widen the box itself.
struct TimePicker: NSViewRepresentable {
    @Binding var time: TimeOfDay
    var isEnabled = true

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = RoomyDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.isBezeled = true
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        picker.setContentHuggingPriority(.required, for: .horizontal)
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.parent = self
        if picker.dateValue != time.pickerDate { picker.dateValue = time.pickerDate }
        picker.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject {
        var parent: TimePicker
        init(_ parent: TimePicker) { self.parent = parent }
        @objc func changed(_ sender: NSDatePicker) {
            parent.time = TimeOfDay(pickerDate: sender.dateValue)
        }
    }

    final class RoomyDatePicker: NSDatePicker {
        override var intrinsicContentSize: NSSize {
            var size = super.intrinsicContentSize
            size.width += 8
            return size
        }
    }
}
