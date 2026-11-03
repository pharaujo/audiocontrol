import OSLog

/// One subsystem for the whole app so `log stream --predicate 'subsystem == "com.pedroaraujo.audiocontrol"'` shows everything.
public enum Log {
    public static let subsystem = "com.pedroaraujo.audiocontrol"
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let discovery = Logger(subsystem: subsystem, category: "discovery")
    public static let tap = Logger(subsystem: subsystem, category: "tap")
    public static let permission = Logger(subsystem: subsystem, category: "permission")
    public static let device = Logger(subsystem: subsystem, category: "device")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}
