/// The updater's rules: version numbers, the release feed, the update decision, the schedule, the checksum file, the
/// install flow's state machine and the order of an install (`InstallSteps`). Pure; the networking, the Security and
/// disk calls and the file replacing are the app's, and are handed to the sequencer as closures.
