namespace NaviApps.DesktopActions;

/// <summary>Portable failures at the shared action serialization boundary.</summary>
public enum ActionDataError
{
    /// <summary>Malformed JSON, mismatched input, or an invalid field value.</summary>
    InvalidData = 1,
    /// <summary>The envelope uses an unsupported schema version.</summary>
    UnsupportedVersion = 2,
    /// <summary>The action identifier is not in this SDK's catalog.</summary>
    UnknownAction = 3,
}

/// <summary>A structured failure reported by the Rust action codec.</summary>
public sealed class ActionDataException : Exception
{
    /// <summary>The portable error category.</summary>
    public ActionDataError Code { get; }
    /// <summary>The unsupported envelope version, when applicable.</summary>
    public long? Version { get; }
    internal ActionDataException(ActionDataError code, string message, long? version) : base(message)
    { Code = code; Version = version; }
}
