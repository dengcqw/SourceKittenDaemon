//
//  Completer.swift
//  SourceKittenDaemon
//
//  Created by Benedikt Terhechte on 12/11/15.
//  Copyright © 2015 Benedikt Terhechte. All rights reserved.
//

import Foundation
import SourceKittenFramework

/**
This keeps the connection to the XPC via SourceKitten and is being called
from the Completion Server to perform completions. */
class Completer {
    
    // The project parser
    var project: Project

    // Need to monitor changes to the .pbxproject and re-fetch
    // project settings.
    let eventStream: FSEventStreamRef
    
    init(project: Project) {
        self.project = project
      
        self.eventStream = FSEventStreamCreate(
                kCFAllocatorDefault,
                { (_) in NotificationCenter.default.post(name: Notification.Name(rawValue: "skdrefresh"), object: nil) },
                nil,
                [project.projectFile.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                2,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))!
      
        let runLoop = RunLoop.main
        FSEventStreamScheduleWithRunLoop(eventStream,
                                         runLoop.getCFRunLoop(),
                                         RunLoopMode.defaultRunLoopMode as CFString)
        FSEventStreamStart(eventStream)

        print("[INFO] Monitoring \(project.projectFile.path) for changes")
        NotificationCenter.default.addObserver(
          forName: NSNotification.Name(rawValue: "skdrefresh"), object: nil, queue: nil) { _ in
            print("[INFO] Refreshing project due to change in: \(project.projectFile.path)")
            do { try self.refresh() }
            catch (let e as CustomStringConvertible) { print("[ERR] Refresh failed: \(e.description)") }
            catch (_) { print("[ERR] Refresh failed: unknown reason") }
        }
    }

    deinit {
        FSEventStreamInvalidate(eventStream)
    }

    func refresh() throws {
        self.project = try project.reissue()
    }
    
    func complete(_ url: URL, offset: Int, prefixString: String = "") -> CompletionResult {
        let path = url.path

        guard let file = File(path: path) 
            else { return .failure(message: "Could not read file") }

        let frameworkSearchPaths: [String] = project.frameworkSearchPaths.reduce([]) { $0 + ["-F", $1] }
        let customSwiftCompilerFlags: [String] = project.customSwiftCompilerFlags

//        let preprocessorFlags: [String] = project.gccPreprocessorDefinitions
//            .reduce([]) { $0 + ["-Xcc", "-D\($1)"] }

        let sourceFiles: [String] = self.sourceFiles()

        // Ugly mutation because `[] + [..] + [..] + [..]` = 'Too complex to solve in reasonable time'
        var compilerArgs: [String] = []
        compilerArgs = compilerArgs + ["-module-name", project.moduleName]
        compilerArgs = compilerArgs + ["-sdk", project.sdkRoot]

        if let platformTarget = project.platformTarget
            { compilerArgs = compilerArgs + ["-target", platformTarget] }

        compilerArgs = compilerArgs + frameworkSearchPaths
        compilerArgs = compilerArgs + customSwiftCompilerFlags
//        compilerArgs = compilerArgs + preprocessorFlags
        compilerArgs = compilerArgs + ["-c"]
        compilerArgs = compilerArgs + [path]
        compilerArgs = compilerArgs + ["-j4"]
        compilerArgs = compilerArgs + sourceFiles

        let contents = file.contents
        let request = Request.codeCompletionRequest(
                          file: path,
                          contents: contents,
                          offset: Int64(offset),
                          arguments: compilerArgs)
      
        let response = CodeCompletionItem.parse(response: request.send())
        
        typealias ResultType = [Dictionary<String, String>]
        var samePrefixItem:ResultType = []
        var prjItem:ResultType = []
        var UIKitItem:ResultType = []
        var FDItem:ResultType = []
        var CGItem:ResultType = []
        var Others:ResultType = []
        
        for item in response {
            if let sourceText = item.sourcetext, sourceText.hasPrefix(prefixString) {
                samePrefixItem.append(item.simpleDictionary())
                continue
            }
            guard let moduleName = item.moduleName else {
                continue
            }
            if moduleName.hasPrefix(self.project.moduleName) {
                prjItem.append(item.simpleDictionary())
            } else if moduleName.hasPrefix("UI") {
                UIKitItem.append(item.simpleDictionary())
            } else if moduleName.hasPrefix("NS") {
                FDItem.append(item.simpleDictionary())
            } else if moduleName.hasPrefix("CG") {
                CGItem.append(item.simpleDictionary())
            } else {
                Others.append(item.simpleDictionary())
            }
        }
        var results:ResultType = []
        results.append(contentsOf: samePrefixItem)
        results.append(contentsOf: prjItem)
        results.append(contentsOf: UIKitItem)
        results.append(contentsOf: FDItem)
        results.append(contentsOf: CGItem)
        results.append(contentsOf: Others)

        return .success(result: results)
    }
    
    func sourceFiles() -> [String] {
        return project.sourceObjects
            .map({ (o: ProjectObject) -> String? in o.relativePath.absoluteURL(forProject: project)?.path })
                                    .filter({ $0 != nil }).map({ $0! })
    }
    
}

extension CodeCompletionItem {
    func simpleDictionary() -> Dictionary<String, String> {
        return ["sourcetext": self.sourcetext!, "name": self.name!]
    }
}
