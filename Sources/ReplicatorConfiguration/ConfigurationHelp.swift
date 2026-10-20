import Foundation

extension ConfigurationOptions {
    public static func help(command: String? = nil, section: String? = nil) throws -> String {
        if let command, !commands.contains(command) {
            throw ConfigurationError(
                "unknown configuration command; choose: " + commands.sorted().joined(separator: ", "))
        }
        if let section, metadata[section] == nil {
            throw ConfigurationError("unknown configuration section or setting; use config-help to list settings")
        }
        let keys = metadata.keys.sorted().filter { key in
            (command == nil || metadata[key]!.commands.contains(command!))
                && (section == nil || key == section! || key.hasPrefix(section! + "."))
        }
        guard !keys.isEmpty else {
            throw ConfigurationError("this section does not apply to the selected command")
        }
        var lines = [
            "Configuration reference" + (command.map { " for " + $0 } ?? " (all commands)"),
            command == "inspect" || command == "blackhole"
                ? "Use --source-config FILE.yaml."
                : "Use --config FILE.yaml."
                    + (command == nil ? " inspect and blackhole use --source-config FILE.yaml." : ""),
            "CLI overrides replace YAML values. Quote YAML lists and maps as one shell argument.",
            "Required means required in its containing section. Other requirements are stated below.",
            "Defaults apply when a setting is omitted. null resets a nullable setting to its default or leaves it unset.",
        ]
        if keys.contains(where: { metadata[$0]!.type == .section }) {
            lines += [
                "Sections are YAML maps, not scalar options. A section example {} shows syntax only; required fields still apply.",
                "Replace a section with --SECTION YAML_MAP. A replacement must include all required fields in that section.",
            ]
        }
        if command == "replay" || command == "recovery" || command == "skip" {
            lines += [
                "This command reads an apply configuration. Source connection fields remain in the file and are validated,",
                "but no source connection is made. Use examples/replay.minimal.yaml as a starting point.",
            ]
        }
        if command == "recovery" || command == "skip" {
            lines.append(
                "These commands validate the apply configuration and saved state. They do not apply rows or connect to the target."
            )
        }
        if command == "inspect" || command == "blackhole" {
            lines.append(
                "The source-only file has no source wrapper. CLI overrides still use the source. prefix. File inspection needs no configuration."
            )
        }
        if command == "ctl" {
            lines.append(
                "ctl reads only stateDirectory. Edit stop limits in YAML before ctl reload; do not pass them as ctl overrides."
            )
        }
        for key in keys {
            let option = metadata[key]!
            let flag = "--" + (key == "version" ? "config.version" : key)
            lines.append("")
            lines.append(option.type == .section ? key + ": (section)" : flag + " " + option.type.rawValue)
            var attributes = [
                option.required ? "required" : "optional", "null: " + (option.nullable ? "allowed" : "not allowed"),
            ]
            if option.type != .section {
                attributes.append("default: " + (option.defaultValue ?? "none"))
            }
            if let units = option.units { attributes.append("units: " + units) }
            lines.append("  " + attributes.joined(separator: "; "))
            if !option.allowedValues.isEmpty {
                lines.append(
                    "  Allowed" + (option.type == .stringList ? " list items: " : ": ")
                        + option.allowedValues.joined(separator: ", "))
            }
            lines.append("  " + (descriptions[key] ?? ""))
            lines.append("  YAML example: " + option.example)
            if command == nil { lines.append("  Commands: " + option.commands.sorted().joined(separator: ", ")) }
        }
        lines.append("\nExamples are YAML values, not complete configurations.")
        if keys.contains(where: { [.stringList, .stringMap].contains(metadata[$0]!.type) }) {
            lines.append(
                "[] clears a list. {} clears a string map. Some lists, such as archive.files, cannot be empty.")
        }
        return lines.joined(separator: "\n")
    }
}
