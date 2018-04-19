//
//  Listener.swift
//  killswitch
//
//  Created by Daniel Skovli on 18/11/17.
//  Copyright © 2017 Daniel Skovli. All rights reserved.
//

import Foundation
import Cocoa
import Alamofire
import Quartz


/*
    Enumeration that holds all the actions this app will take after receving the kill command
    Defaults to `lock`. Used by AppDelegate, and configured in ViewController/prefWindow
 */
enum KillAction : String {
    case lock = "Lock"
    case logout = "Logout"
    case sleep = "Sleep"
    case shutdown = "Shutdown"
    
    static let allValues = [lock, logout, sleep, shutdown] // this is BS, but swift won't let you iterate over enums
}


/*
    The listener class
 */
class Listener {
    var ready : Bool = false
    var run : Bool = false
    let interval : UInt32 = 3
    var url : String
    var token : String
    var action : KillAction
    let queue = DispatchQueue(label: "KillswitchListener")
    let ad = NSApplication.shared.delegate as! AppDelegate
    
    
    // Initialise the class
    init(url: String, token: String, action: KillAction) {
        self.url = url + token
        self.token = token
        self.action = action
        
        Alamofire.SessionManager.default.session.configuration.timeoutIntervalForRequest = 15 // in seconds
        Alamofire.SessionManager.default.session.configuration.timeoutIntervalForResource = 15 // in seconds
    }
    
    
    // Public: Starts the listening process at interval set by `self.interval`
    func Start() -> Bool {
        self.run = true
        
        queue.async {
            self.Iterate()
        }
        
        return true // Future
    }
    
    
    // Public: Stops the listening process after current iteration
    func Stop() -> Bool {
        self.run = false
        return true // Future
    }
    
    
    // Private: While screen is active, load server JSON and take appropriate action
    private func Fetch() {
        
        // If the screen is locked, skip the JSON download and try again in the next iteration
        let stats = CGSessionCopyCurrentDictionary() as? [String: AnyObject]
        if (stats?["CGSSessionScreenIsLocked"] != nil) {
            self.queue.async {
                sleep(self.interval)
                self.Iterate()
            }
            //print("skipping check, we're locked")
            return
        }
        
        // Check if we're either authenticated or trying to be
        if ((!self.ad.authenticated && !self.ad.firstLoad) || self.token == "") {
            self.ad.status = "Not signed in. Please complete setup"
            self.ad.isRunning = false
            self.ad.updateGUI()
            self.ad.firstLoad = false
            return;
        }
        
        // If not, we're good to go. Fire up Alamo
        Alamofire.request(self.url).responseJSON { response in
            if let json = response.result.value {
                let parsed = json as! NSDictionary
                //print("Got JSON: " + String(parsed.count))
                let error = parsed["error"] as! Bool
                if (!error) {
                    let killswitch = parsed["killswitch"] as! Bool
                    UserDefaultsManager.shared.lastStatus = killswitch
                    self.ad.authenticated = true
                    self.ad.isRunning = true
                    
                    // Do the actual work, as decided by the user (`self.action`)
                    if (killswitch) {
                        switch (self.action) {
                            case .lock:
                                print("Locking system")
                                self.Shell("pmset displaysleepnow")
                                break
                            case .shutdown:
                                print("Shutting down")
                                self.shutdown(command: kAEShutDown)
                                break
                            case .logout:
                                print("Logging out")
                                //self.Shell("/System/Library/CoreServices/Menu\\ Extras/User.menu/Contents/Resources/CGSession -suspend")
                                self.shutdown(command: kAEReallyLogOut)
                                break
                            case .sleep:
                                print("Sleeping")
                                self.shutdown(command: kAESleep)
                                break
                        }
                    }
                } else {
                    self.ad.status = parsed["error"] as! NSString
                    self.ad.authenticated = false
                    self.ad.isRunning = false
                    print(error)
                }
            } else {
                self.ad.status = "Server unreachable..."
                // Consider fetching UserDefaultsManager.shared.lastStatus here, for persistance
                // Expose as option in the settings pane
            }
            
            self.ad.firstLoad = false;
            self.ad.updateGUI()
            
            // Next iteration
            self.queue.async {
                sleep(self.interval)
                self.Iterate()
            }
        }
    }
    
    
    // Private: Step to next iteration (infinite loop until !self.run)
    private func Iterate() {
        if (self.run) {
            self.Fetch()
        }
    }
    
    
    // Private: Run system commands
    @discardableResult private func Shell(_ args: String) -> Int32 {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", args]
        task.launch()
        task.waitUntilExit()
        return task.terminationStatus
    }
    
    
    // Private: shutdown/logout/sleep sleep system
    // Borrowed from:
    //      https://gitlab.com/Mactroll/DEPNotify/blob/master/DEPNotify/ViewController.swift
    //      https://developer.apple.com/library/content/qa/qa1134/_index.html
    private func shutdown(command: AEEventID) {
        var targetDesc: AEAddressDesc = AEAddressDesc.init()
        var psn = ProcessSerialNumber(highLongOfPSN: UInt32(0), lowLongOfPSN: UInt32(kSystemProcess))
        var eventReply: AppleEvent = AppleEvent(descriptorType: UInt32(typeNull), dataHandle: nil)
        var eventToSend: AppleEvent = AppleEvent(descriptorType: UInt32(typeNull), dataHandle: nil)

        var status: OSErr = AECreateDesc(
            UInt32(typeProcessSerialNumber),
            &psn,
            MemoryLayout<ProcessSerialNumber>.size,
            &targetDesc
        )
        
        status = AECreateAppleEvent(
            UInt32(kCoreEventClass),
            command,
            &targetDesc,
            AEReturnID(kAutoGenerateReturnID),
            AETransactionID(kAnyTransactionID),
            &eventToSend
        )
        
        AEDisposeDesc(&targetDesc)
        
        let osstatus = AESendMessage(
            &eventToSend,
            &eventReply,
            AESendMode(kAENormalPriority),
            kAEDefaultTimeout
        )
    }
}