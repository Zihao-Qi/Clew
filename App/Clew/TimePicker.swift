import AppKit
import ClewCore
import ClewDomain
import SwiftUI

/// An hour-and-minute picker whose text box fits its text. SwiftUI's DatePicker
/// uses NSDatePicker's intrinsic width, which is a few points short for "6:00 PM"
/// (the M touches the border), and a SwiftUI frame cannot widen the box itself.
///
/// The hour or the minutes are selected by clicking, and the arrow keys change that
/// part. With `quarterHours`, the minutes step by 15 and a typed minute becomes the
/// nearest quarter when the field is left (user, 2026-11-18: the timeline's times).
struct TimePicker: NSViewRepresentable {
    @Binding var time: TimeOfDay
    var isEnabled = true
    var quarterHours = false

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = RoomyDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.isBezeled = true
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        picker.setContentHuggingPriority(.required, for: .horizontal)
        if quarterHours {
            picker.delegate = context.coordinator
            // Leaving the field shows the quarter it was rounded to.
            picker.onResign = { [weak picker, coordinator = context.coordinator] in
                guard let picker else { return }
                picker.dateValue = coordinator.parent.time.pickerDate
            }
        }
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.parent = self
        // While a quarter-hour field is being typed in, the typed minute stays as typed.
        let editing = quarterHours && picker.window?.firstResponder === picker
        if !editing, picker.dateValue != time.pickerDate { picker.dateValue = time.pickerDate }
        picker.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSDatePickerCellDelegate {
        var parent: TimePicker
        init(_ parent: TimePicker) { self.parent = parent }

        @objc func changed(_ sender: NSDatePicker) {
            let time = TimeOfDay(pickerDate: sender.dateValue)
            parent.time = parent.quarterHours ? QuarterTime.nearest(time) : time
        }

        /// An arrow key on the minutes proposes one minute more or less: make it a quarter.
        func datePickerCell(_ cell: NSDatePickerCell,
                            validateProposedDateValue proposed: AutoreleasingUnsafeMutablePointer<NSDate>,
                            timeInterval: UnsafeMutablePointer<TimeInterval>?) {
            let old = TimeOfDay(pickerDate: cell.dateValue)
            let new = TimeOfDay(pickerDate: proposed.pointee as Date)
            let stepped = QuarterTime.stepped(from: old, to: new)
            if stepped != new { proposed.pointee = stepped.pickerDate as NSDate }
        }
    }

    final class RoomyDatePicker: NSDatePicker {
        var onResign: (() -> Void)?

        override var intrinsicContentSize: NSSize {
            var size = super.intrinsicContentSize
            size.width += 8
            return size
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { onResign?() }
            return resigned
        }
    }
}
