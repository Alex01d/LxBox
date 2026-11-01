# Task 700: additive libbox APIs are reflected so the production AAR may be older.
-keepclassmembers class io.nekohasekai.libbox.Libbox {
    public static boolean tailscaleAWGSupported();
}
-keepclassmembers class io.nekohasekai.libbox.TailscaleEndpointStatus {
    public *** getTransport();
}
-keep class io.nekohasekai.libbox.TailscaleTransportStatus {
    public *;
}
