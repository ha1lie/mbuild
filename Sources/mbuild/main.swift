import ArgumentParser
import Foundation

enum MInstallError: Error {
    case swiftFailure
    case writeFailure
    case buildFailure
    case sapFailure
    case prefsFailure
    case zipFailure
    case installFailure
}

struct mbuild: ParsableCommand {
    static var configuration =
                CommandConfiguration(abstract: "Install and compile Maple Leafs")
    
    @Flag(help: "Create a packaged and distributable Leaf")
    var releaseMode: Bool = false
    
    @Argument(help: "The name of this Leaf matching your Xcode project name")
    var name: String
    
    @Flag(name: .long, help: "Include preferences")
    var prefs: Bool = false
    
    @Option(name: .shortAndLong, help: "Destination for compiled Maple Leaf. Ignored if not in release mode")
    var leafDestination: String?
    
    func validate() throws {
        var contents: [String] = []
        
        do {
            contents = try FileManager.default.contentsOfDirectory(atPath: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources").path)
        } catch {
            throw ValidationError("Must run script from inside of an SPM Project folder")
        }
        
        if contents.contains(self.name) {
            return
        }
        
        throw ValidationError("Name argument must explicitly match the projects name")
    }
    
    func run() throws {
        var mode: String = "debug"
        
        if self.releaseMode  {
            mode = "release"
        }
        
        let sbOut = Pipe()
        sbOut.fileHandleForReading.readabilityHandler = { (fileHandle) -> Void in
            if let ns = String(data: fileHandle.availableData, encoding: .utf8) {
                print(ns, terminator: "")
            }
        }
        let sbProc = Process()
        sbProc.launchPath = "/usr/bin/swift"
        sbProc.arguments = ["build", "-c", mode]
        sbProc.standardError = sbOut
        sbProc.standardOutput = sbOut
        sbProc.standardInput = nil
        
        do {
            print("[-] Running `swift build -c \(mode)`")
            try sbProc.run()
        } catch {
            print("[-] Failed to run swift build. Ensure developer tools are installed")
            throw MInstallError.swiftFailure
        }
        
        sbProc.waitUntilExit()
        
        print("[+] Finished swift build with exit code: \(sbProc.terminationStatus)")
        
        guard sbProc.terminationStatus == 0 else {
            print("[-] Build terminated with a non-zero status. Terminating.")
            throw MInstallError.buildFailure
        }
        
        //MARK: Should be done with swift build
        
        let containerFolder: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("LeafContainer")
        
        do {
            try FileManager.default.createDirectory(atPath: containerFolder.path, withIntermediateDirectories: true)
        } catch {
            print("[-] Failed to write to this directory. Ensure you have write permissions here.")
            throw MInstallError.writeFailure
        }
        
        defer {
            // Get rid of it on exit
            try? FileManager.default.removeItem(at: containerFolder)
            if !self.releaseMode {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("\(self.name).zip"))
            }
        }
        
        // Copy the executable in!
        print("[-] Copying executable to container folder")
        
        let execFile: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/\(mode)/lib\(self.name).dylib")
        print("Looking for: \(execFile.path)")
        if FileManager.default.fileExists(atPath: execFile.path) {
            // Copy it
            do {
                try FileManager.default.copyItem(at: execFile, to: containerFolder.appendingPathComponent(self.name))
            } catch {
                print("[-] Failed to copy executable file to leaf container. Terminating.")
                throw MInstallError.writeFailure
            }
        } else {
            print("[-] New executable not found. Terminating.")
            throw MInstallError.buildFailure
        }
        
        print("[+] Copied executable to container folder")
        
        // Copy the .sap in
        print("[-] Copying info.sap from sources directory")
        
        let sapFile: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/\(self.name)/info.sap")
        
        if FileManager.default.fileExists(atPath: sapFile.path) {
            // Copy it
            do {
                try FileManager.default.copyItem(at: sapFile, to: containerFolder.appendingPathComponent("info.sap"))
            } catch {
                print("[-] Failed to copy info.sap to container folder. Terminating.")
                throw MInstallError.sapFailure
            }
        } else {
            print("[-] info.sap file not found. Must exist at top level of the Sources directory. Terminating")
            throw MInstallError.sapFailure
        }
        
        print("[+] Copied info.sap from sources directory")
        
        // If prefs; Copy prefs after running
        if self.prefs {
            print("[-] Leaf contains preferences. Building")
            
            let pFile: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/\(self.name)/\(self.name)Preferences.swift")
            
            let psProc = Process()
            let psOut = Pipe()
            psOut.fileHandleForReading.readabilityHandler = { (fileHandle) -> Void in
                if let ns = String(data: fileHandle.availableData, encoding: .utf8) {
                    print(ns, terminator: "")
                }
            }
            psProc.launchPath = "/usr/bin/swift"
            psProc.arguments = [pFile.path, containerFolder.appendingPathComponent("prefs.json").path]
            psProc.standardError = psOut
            psProc.standardOutput = psOut
            psProc.standardInput = nil
            
            do {
                print("[-] Compiling preferences")
                try psProc.run()
            } catch {
                print("[-] Failed to compile preferences. Terminating.")
                throw MInstallError.prefsFailure
            }
            
            psProc.waitUntilExit()
            
            print("[+] Successfully compiled preferences")
        }
        
        // Zip the file!
        print("[-] Zipping compiled leaf")
        
        let zipProc = Process()
        zipProc.standardInput = nil
        zipProc.standardOutput = nil
        zipProc.standardError = nil
        zipProc.launchPath = "/usr/bin/zip"
        zipProc.arguments = ["-r", "\(self.name).zip", "LeafContainer"]
        
        do {
            try zipProc.run()
        } catch {
            print("[-] Failed to run zip command. Terminating.")
            throw MInstallError.zipFailure
        }
        
        zipProc.waitUntilExit()
        
        let zipFile: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("\(self.name).zip")
        
        if FileManager.default.fileExists(atPath: zipFile.path) {
            print("[+] Created compiled leaf")
        } else {
            print("[-] Zip command failed. Terminating.")
            throw MInstallError.zipFailure
        }
        
        // Move it to the destination
        if !self.releaseMode {
            print("[-] Installing to Maple")
            
            do {
                try FileManager.default.copyItem(at: zipFile, to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Maple/Development/\(self.name).zip"))
            } catch {
                print("[-] Failed to copy leaf to Maple. Terminating.")
                throw MInstallError.installFailure
            }
            
            print("[+] Installed to Maple")
        }
        
        print("[+] Completed")
    }
}

mbuild.main()
