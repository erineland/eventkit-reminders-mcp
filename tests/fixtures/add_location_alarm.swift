// Test fixture: give a reminder a location alert, which the server itself can't create.
// Refuses any reminder that isn't in a throwaway test list. Usage: add_location_alarm <reminder-id>
import CoreLocation
import EventKit

let ek = EKEventStore()
let sem = DispatchSemaphore(value: 0)
ek.requestFullAccessToReminders { _, _ in sem.signal() }
sem.wait()
guard CommandLine.arguments.count == 2, let r = ek.calendarItem(withIdentifier: CommandLine.arguments[1]) as? EKReminder else {
    fatalError("usage: add_location_alarm <reminder-id>")
}
precondition(r.calendar.title.hasPrefix("eventkit-mcp-test-"), "refusing: not in a test list")
let loc = EKStructuredLocation(title: "Test Place")
loc.geoLocation = CLLocation(latitude: 51.5007, longitude: -0.1246)   // a public landmark, not anyone's address
loc.radius = 100
let alarm = EKAlarm()
alarm.structuredLocation = loc
alarm.proximity = .enter
r.addAlarm(alarm)
try! ek.save(r, commit: true)
