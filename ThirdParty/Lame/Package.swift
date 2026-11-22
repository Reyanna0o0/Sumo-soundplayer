// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SimoLame", platforms: [.iOS(.v18), .macOS(.v13)],
    products: [.library(name: "CLame", targets: ["CLame"])],
    targets: [.target(name: "CLame", path: ".", sources: [
        "VbrTag", "bitstream", "encoder", "fft", "gain_analysis", "id3tag", "lame",
        "newmdct", "presets", "psymodel", "quantize", "quantize_pvt", "reservoir",
        "set_get", "tables", "takehiro", "util", "vbrquantize", "version", "mpglib_interface"
    ].map { "lame-4.0/libmp3lame/" + $0 + ".c" }, publicHeadersPath: "include",
    cSettings: [.define("HAVE_CONFIG_H"), .headerSearchPath("config"),
        .headerSearchPath("lame-4.0"), .headerSearchPath("lame-4.0/include"),
        .headerSearchPath("lame-4.0/libmp3lame")])], cLanguageStandard: .gnu17)
