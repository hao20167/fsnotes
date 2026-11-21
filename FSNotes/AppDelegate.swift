//
//  AppDelegate.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 7/20/17.
//  Copyright © 2017 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa
import UserNotifications

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var prefsWindowController: PrefsWindowController?
    var aboutWindowController: AboutWindowController?
    var statusItem: NSStatusItem?

    public var urls: [URL]? = nil
    public var url: URL? = nil
    public var newName: String? = nil
    public var newContent: String? = nil
    public var folderName: String? = nil
    public var newWindow: Bool = false

    public static var mainWindowController: MainWindowController?
    public static var noteWindows = [NSWindowController]()
    
    public static var appTitle: String {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        return name ?? Bundle.main.object(forInfoDictionaryKey: kCFBundleNameKey as String) as! String
    }
    
    public static var gitProgress: GitProgress?

    override init() {
        // Fork: take over the settings of the original FSNotes. Must run before anything
        // touches Storage (the main window loads the notes before willFinishLaunching).
        ForkMigration.runIfNeeded()
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        checkStorageChanges()
        loadDockIcon()
        
        if UserDefaultsManagement.showInMenuBar {
            constructMenu()
        }
        
        if !UserDefaultsManagement.showDockIcon {
            let transformState = ProcessApplicationTransformState(kProcessTransformToUIElementApplication)
            var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
            TransformProcessType(&psn, transformState)

            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: Private mode

    private static let privateModeMenuIdentifier = NSUserInterfaceItemIdentifier("view.privateMode")

    private func setupPrivateModeMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }

        func find(_ identifier: String, in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.identifier?.rawValue == identifier { return item }
                if let sub = item.submenu, let found = find(identifier, in: sub) { return found }
            }
            return nil
        }

        // Cmd+Shift+H was "History": move it to Ctrl+Cmd+H
        if let history = find("fileMenu.history", in: mainMenu) {
            history.keyEquivalent = "h"
            history.keyEquivalentModifierMask = [.command, .control]
        }

        guard find(AppDelegate.privateModeMenuIdentifier.rawValue, in: mainMenu) == nil,
              let viewMenu = mainMenu.items.first(where: { $0.submenu?.identifier?.rawValue == "viewMenu" })?.submenu
        else { return }

        let item = NSMenuItem(title: NSLocalizedString("Private Mode", comment: ""), action: #selector(togglePrivateMode(_:)), keyEquivalent: "h")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.identifier = AppDelegate.privateModeMenuIdentifier
        item.target = self
        item.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
        item.state = UserDefaultsManagement.privateMode ? .on : .off

        // Put it right after "Toggle Preview"
        let index = viewMenu.items.firstIndex(where: { $0.action == NSSelectorFromString("togglePreview:") }).map { $0 + 1 } ?? 0
        viewMenu.insertItem(item, at: index)

        // Private mode: lines shown around the current one
        let linesItem = NSMenuItem(title: NSLocalizedString("Private Mode Lines", comment: ""), action: nil, keyEquivalent: "")
        let linesMenu = NSMenu(title: linesItem.title)
        for value in [0, 1, 2, 3, 5, 10] {
            let title = value == 0
                ? NSLocalizedString("Current line only", comment: "")
                : String(format: NSLocalizedString("±%d lines", comment: ""), value)
            let option = NSMenuItem(title: title, action: #selector(setPrivateModeLines(_:)), keyEquivalent: "")
            option.target = self
            option.tag = value
            option.state = UserDefaultsManagement.privateModeContextLines == value ? .on : .off
            linesMenu.addItem(option)
        }
        linesItem.submenu = linesMenu
        viewMenu.insertItem(linesItem, at: index + 1)

        let vimItem = NSMenuItem(title: NSLocalizedString("Vim Mode", comment: ""), action: #selector(toggleVimMode(_:)), keyEquivalent: "")
        vimItem.target = self
        vimItem.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        vimItem.state = UserDefaultsManagement.vimMode ? .on : .off
        viewMenu.insertItem(vimItem, at: index + 2)
    }

    @objc func setPrivateModeLines(_ sender: NSMenuItem) {
        UserDefaultsManagement.privateModeContextLines = sender.tag
        sender.menu?.items.forEach { $0.state = $0.tag == sender.tag ? .on : .off }

        for editor in AppDelegate.getEditTextViews() {
            editor.needsDisplay = true
        }
    }

    @objc func toggleVimMode(_ sender: Any?) {
        UserDefaultsManagement.vimMode.toggle()
        (sender as? NSMenuItem)?.state = UserDefaultsManagement.vimMode ? .on : .off

        for editor in AppDelegate.getEditTextViews() {
            editor.vimModeDidToggle()
        }
    }

    @objc func togglePrivateMode(_ sender: Any?) {
        UserDefaultsManagement.privateMode.toggle()

        if let item = sender as? NSMenuItem {
            item.state = UserDefaultsManagement.privateMode ? .on : .off
        } else if let mainMenu = NSApp.mainMenu {
            for top in mainMenu.items {
                if let item = top.submenu?.items.first(where: { $0.identifier == AppDelegate.privateModeMenuIdentifier }) {
                    item.state = UserDefaultsManagement.privateMode ? .on : .off
                }
            }
        }

        for editor in AppDelegate.getEditTextViews() {
            editor.needsDisplay = true
        }

        if let vc = ViewController.shared() {
            vc.notesTableView.reloadData()
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Ensure the font panel is closed when the app starts, in case it was
        // left open when the app quit.
        NSFontManager.shared.fontPanel(false)?.orderOut(self)

        applyAppearance()
        setupPrivateModeMenu()
        ForkMigration.finishAfterLaunch()

        #if CLOUD_RELATED_BLOCK
        if let iCloudDocumentsURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents").standardized {
            
            if (!FileManager.default.fileExists(atPath: iCloudDocumentsURL.path, isDirectory: nil)) {
                do {
                    try FileManager.default.createDirectory(at: iCloudDocumentsURL, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    print("Home directory creation: \(error)")
                }
            }
        }
        #endif

        if UserDefaultsManagement.storagePath == nil {
            self.requestStorageDirectory()
            return
        }

        let storyboard = NSStoryboard(name: "Main", bundle: nil)
        
        guard let mainWC = storyboard.instantiateController(withIdentifier: "MainWindowController") as? MainWindowController else {
            fatalError("Error getting main window controller")
        }
        
        AppDelegate.mainWindowController = mainWC
        mainWC.window?.makeKeyAndOrderFront(nil)
    }
        
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if (!flag) {
            AppDelegate.mainWindowController?.makeNew()
        }
                
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        UserDefaultsManagement.crashedLastTime = false
        
        AppDelegate.saveWindowsState()
        
        Storage.shared().saveUploadPaths()
        
        let webkitPreview = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wkPreview")
        try? FileManager.default.removeItem(at: webkitPreview)

        let printDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Print")
        try? FileManager.default.removeItem(at: printDir)

        let encryption = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Encryption")
        try? FileManager.default.removeItem(at: encryption)

        var temporary = URL(fileURLWithPath: NSTemporaryDirectory())
        temporary.appendPathComponent("ThumbnailsBig")
        try? FileManager.default.removeItem(at: temporary)

        let storyboard = NSStoryboard(name: "Main", bundle: nil)
        guard let mainWC = storyboard.instantiateController(withIdentifier: "MainWindowController") as? MainWindowController else {
            return
        }

        if let x = mainWC.window?.frame.origin.x, let y = mainWC.window?.frame.origin.y {
            UserDefaultsManagement.lastScreenX = Int(x)
            UserDefaultsManagement.lastScreenY = Int(y)
        }
        
        Storage.shared().saveProjectsCache()
        
        print("Termination end, crash status: \(UserDefaultsManagement.crashedLastTime)")
    }
    
    private static func saveWindowsState() {
        var result = [[String: Any]]()
                
        let noteWindows = self.noteWindows.sorted(by: { $0.window!.orderedIndex > $1.window!.orderedIndex })
        for windowController in noteWindows {
            if let frame = windowController.window?.frame,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: frame, requiringSecureCoding: true),
               let controller = windowController.contentViewController as? NoteViewController,
                   let note = controller.editor.note {


                let key = windowController.window?.isKeyWindow == true

                result.append(["frame": data, "preview": controller.editor.isPreviewEnabled(), "url": note.url, "main": false, "key": key])
            }
        }
        
        // Main frame
        if let vc = ViewController.shared(), let note = vc.editor?.note, let mainFrame = vc.view.window?.frame,
           let data = try? NSKeyedArchiver.archivedData(withRootObject: mainFrame, requiringSecureCoding: true) {

            let key = vc.view.window?.isKeyWindow == true
            
            result.append(["frame": data, "preview": vc.editor.isPreviewEnabled(), "url": note.url, "main": true, "key": key])
        }
    
        let projectsData = try? NSKeyedArchiver.archivedData(withRootObject: result, requiringSecureCoding: true)
        if let documentDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? projectsData?.write(to: documentDir.appendingPathComponent("editors.settings"))
        }
    }
    
    private func applyAppearance() {
        if UserDefaultsManagement.appearanceType == .Dark {
            NSApp.appearance = NSAppearance.init(named: NSAppearance.Name.darkAqua)
            UserDataService.instance.isDark = true
        }

        if UserDefaultsManagement.appearanceType == .Light {
            NSApp.appearance = NSAppearance.init(named: NSAppearance.Name.aqua)
            UserDataService.instance.isDark = false
        }

        if UserDefaultsManagement.appearanceType == .System {
            UserDataService.instance.isDark = NSApp.effectiveAppearance.isDark
        }
    }
    
    private func restartApp() {
        guard let resourcePath = Bundle.main.resourcePath else { return }
        
        let url = URL(fileURLWithPath: resourcePath)
        let path = url.deletingLastPathComponent().deletingLastPathComponent().absoluteString
        let task = Process()
        
        task.launchPath = "/usr/bin/open"
        task.arguments = [path]
        task.launch()
        
        exit(0)
    }
    
    private func requestStorageDirectory() {
        var directoryURL: URL? = nil
        if let path = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first {
            directoryURL = URL(fileURLWithPath: path)
        }
        
        let panel = NSOpenPanel()
        panel.directoryURL = directoryURL
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Please select default storage directory"
        panel.begin { (result) -> Void in
            if result == .OK {
                guard let url = panel.url else {
                    return
                }
                
                let bookmarks = SandboxBookmark.sharedInstance()
                bookmarks.save(url: url)

                UserDefaultsManagement.storageType = .custom
                UserDefaultsManagement.customStoragePath = url.path
                
                self.restartApp()
            } else {
                exit(EXIT_SUCCESS)
            }
        }
    }
    
    func constructMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button, let image = NSImage(named: "menuBar") {
            image.size.width = 20
            image.size.height = 20
            button.image = image
        }

        statusItem?.button?.action = #selector(AppDelegate.clickStatusBarItem(sender:))
        statusItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    public func attachMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: NSLocalizedString("New Note", comment: ""), action: #selector(AppDelegate.new(_:)), keyEquivalent: "n"))

        let newWindow = NSMenuItem(title: NSLocalizedString("New Note in New Window", comment: ""), action: #selector(AppDelegate.createInNewWindow(_:)), keyEquivalent: "n")
        var modifier = NSEvent.modifierFlags
        modifier.insert(.command)
        modifier.insert(.shift)
        newWindow.keyEquivalentModifierMask = modifier
        menu.addItem(newWindow)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("Search and create", comment: ""), action: #selector(AppDelegate.searchAndCreate(_:)), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Settings", comment: ""), action: #selector(AppDelegate.openPreferences(_:)), keyEquivalent: ","))

        let lock = NSMenuItem(title: NSLocalizedString("Lock All Encrypted", comment: ""), action: #selector(ViewController.shared()?.lockAll(_:)), keyEquivalent: "l")
        lock.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(lock)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("Quit FSNotes", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.delegate = self
        statusItem?.menu = menu
    }

    @objc func clickStatusBarItem(sender: NSStatusItem) {
        let event = NSApp.currentEvent!

        if event.type == NSEvent.EventType.leftMouseUp {
            
            // Hide active not hidden and not miniaturized
            if !NSApp.isHidden && NSApp.isActive {
                if let mainWindow = AppDelegate.mainWindowController?.window, !mainWindow.isMiniaturized {
                    NSApp.hide(nil)
                    return
                }
            }
            
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            
            AppDelegate.mainWindowController?.window?.makeKeyAndOrderFront(nil)
            ViewController.shared()?.search.becomeFirstResponder()
            
            return
        }

        attachMenu()

        DispatchQueue.main.async {
            if let statusItem = self.statusItem, let button = statusItem.button {
                statusItem.menu?.popUp(positioning: nil, at: NSPoint(x: button.frame.origin.x, y: button.frame.height + 10), in: button)
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem?.menu = nil
    }
    
    // MARK: IBActions
    
    @IBAction func openMainWindow(_ sender: Any) {
        AppDelegate.mainWindowController?.makeNew()
    }
    
    @IBAction func openHelp(_ sender: Any) {
        NSWorkspace.shared.open(URL(string: "https://github.com/glushchenko/fsnotes/wiki")!)
    }

    @IBAction func openBugReports(_ sender: Any) {
        NSWorkspace.shared.open(URL(string: "https://github.com/glushchenko/fsnotes/issues/new?template=bug_report.yml")!)
    }

    @IBAction func openSite(_ sender: Any) {
        NSWorkspace.shared.open(URL(string: "https://fsnot.es")!)
    }
    
    @IBAction func openPreferences(_ sender: Any?) {
        if prefsWindowController == nil {
            let storyboard = NSStoryboard(name: "Main", bundle: nil)
            
            prefsWindowController = storyboard.instantiateController(withIdentifier: "Preferences") as? PrefsWindowController
        }
        
        guard let prefsWindowController = prefsWindowController else { return }
        
        prefsWindowController.showWindow(nil)
        prefsWindowController.window?.makeKeyAndOrderFront(prefsWindowController)
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @IBAction func new(_ sender: Any?) {
        AppDelegate.mainWindowController?.makeNew()
        NSApp.activate(ignoringOtherApps: true)
        ViewController.shared()?.fileMenuNewNote(self)
    }
    
    @IBAction func createInNewWindow(_ sender: Any?) {
        AppDelegate.mainWindowController?.makeNew()
        NSApp.activate(ignoringOtherApps: true)
        ViewController.shared()?.createInNewWindow(self)
    }
    
    @IBAction func searchAndCreate(_ sender: Any?) {
        AppDelegate.mainWindowController?.makeNew()
        NSApp.activate(ignoringOtherApps: true)
        
        guard let vc = ViewController.shared() else { return }
        
        DispatchQueue.main.async {
            vc.search.window?.makeFirstResponder(vc.search)
        }
    }
    
    @IBAction func removeMenuBar(_ sender: Any?) {
        guard let statusItem = statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
    }
    
    @IBAction func addMenuBar(_ sender: Any?) {
        constructMenu()
    }

    @IBAction func showAboutWindow(_ sender: AnyObject) {
        if aboutWindowController == nil {
            let storyboard = NSStoryboard(name: "Main", bundle: nil)

            aboutWindowController = storyboard.instantiateController(withIdentifier: "About") as? AboutWindowController
        }

        guard let aboutWindowController = aboutWindowController else { return }

        aboutWindowController.showWindow(nil)
        aboutWindowController.window?.makeKeyAndOrderFront(aboutWindowController)

        NSApp.activate(ignoringOtherApps: true)
    }

    public func loadDockIcon() {
        let appDockTile = NSApplication.shared.dockTile

        // Only the classic icon needs a custom Dock tile. For the default icon
        // the tile is left to the system, so it follows the Dark/Clear/Tinted
        // icon style on macOS 26+.
        if #available(OSX 10.12, *) {
            if UserDefaultsManagement.dockIcon == 1, let image = NSImage(named: "AppIconClassic") {
                appDockTile.contentView = NSImageView(image: image)
            } else {
                appDockTile.contentView = nil
            }
        }

        appDockTile.display()
    }

    private func checkStorageChanges() {
        if Storage.shared().shouldMovePrompt,
            let local = UserDefaultsManagement.localDocumentsContainer,
            let iCloudDrive = UserDefaultsManagement.iCloudDocumentsContainer
        {
            let message = NSLocalizedString("We are detect that you are install FSNotes from Mac App Store with default storage in iCloud Drive, do you want to move old database in iCloud Drive?", comment: "")

            promptToMoveDatabase(from: local, to: iCloudDrive, messageText: message)
        }
    }

    public func promptToMoveDatabase(from currentURL: URL, to url : URL, messageText: String) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText =
            NSLocalizedString("Otherwise, the database of your notes will be available at: ", comment: "") + currentURL.path

        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("No", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Yes", comment: ""))

        if alert.runModal() == .alertSecondButtonReturn {
            move(from: currentURL, to: url)

            let localTrash = currentURL.appendingPathComponent("Trash", isDirectory: true)
            let cloudTrash = url.appendingPathComponent("Trash", isDirectory: true)

            move(from: localTrash, to: cloudTrash)
        }
    }

    private func move(from currentURL: URL, to url: URL) {
        if let list = try? FileManager.default.contentsOfDirectory(at: currentURL, includingPropertiesForKeys: nil, options: .init()) {

            if !FileManager.default.fileExists(atPath: currentURL.path) {
                return
            }

            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            }

            for item in list {
                let fileName = item.lastPathComponent

                do {
                    let dst = url.appendingPathComponent(fileName)
                    try FileManager.default.moveItem(at: item, to: dst)
                } catch {

                    if ["Trash", "Welcome"].contains(fileName) {
                        continue
                    }

                    let exist = NSAlert()
                    var message = NSLocalizedString("We can not move \"{DST_PATH}\" because this item already exist in selected destination.", comment: "")

                    message = message.replacingOccurrences(of: "{DST_PATH}", with: item.path)

                    exist.messageText = message
                    exist.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                    exist.runModal()
                }
            }
        }
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {

        ViewController.shared()?.restoreUserActivityState(userActivity)

        return true
    }

    func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {

        return true
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    public static func getEditTextViews() -> [EditTextView] {
        var views = getOpenedEditTextViews()
                
        if let controller = mainWindowController?.contentViewController as? ViewController {
            views.append(controller.editor)
        }
        
        return views
    }
    
    public static func getOpenedEditTextViews() -> [EditTextView] {
        var views = [EditTextView]()
        
        for window in noteWindows {
            if let controller = window.contentViewController as? NoteViewController {
                views.append(controller.editor)
            }
        }
        
        return views
    }
}


// MARK: - Fork migration

/// One-time import of the original FSNotes settings, so this build can simply replace
/// FSNotes.app in /Applications. The original app is sandboxed (its data lives in its
/// container); this build is not, so it reads the container once and never writes there.
enum ForkMigration {
    private static let doneKey = "forkMigrationDone"
    private static let gitPendingKey = "forkGitImportPending"
    private static let summaryKey = "forkMigrationSummary"
    /// Testing only: a folder laid out like the original container's `Data` directory
    private static let sourceOverrideKey = "forkMigrationSource"

    // Keys handled separately or not worth carrying over
    private static let skippedKeys: Set<String> = ["storageType", "storageUrl", "crashedLastTime"]

    private static var defaults: UserDefaults { UserDefaults.standard }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private static var sourceData: URL {
        if let override = defaults.string(forKey: sourceOverrideKey), !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Containers/co.fluder.FSNotes/Data", isDirectory: true)
    }

    static func runIfNeeded() {
        guard !defaults.bool(forKey: doneKey) else { return }
        print("Fork migration: importing settings of the original FSNotes")

        let fm = FileManager.default
        let source = sourceData
        let plist = source.appendingPathComponent("Library/Preferences/co.fluder.FSNotes.plist")

        // Nothing to import (fresh install): never ask again
        guard fm.fileExists(atPath: source.path) else {
            defaults.set(true, forKey: doneKey)
            return
        }

        // Reading another app's container may show a macOS permission prompt;
        // if access is refused, try again next launch.
        guard let original = NSDictionary(contentsOf: plist) as? [String: Any] else { return }

        var summary = [String]()

        // 1. Preferences (fonts, theme, window sizes, git interval…)
        var copied = 0
        for (key, value) in original where !skippedKeys.contains(key) {
            defaults.set(value, forKey: key)
            copied += 1
        }
        summary.append("\(copied) settings")

        // 2. Notes folder (real path: folders found on disk are matched against it)
        if let found = storagePath(from: original, source: source) {
            let path = realPath(found)
            defaults.set(StorageType.custom.rawValue, forKey: "storageType")
            defaults.set(path, forKey: "storageUrl")
            summary.append("notes folder: \(path)")
        }

        // 3. Git repositories, SSH keys and per-folder settings files (never overwrite)
        let sourceSupport = source.appendingPathComponent("Library/Application Support", isDirectory: true)
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let repos = copyMissing(from: sourceSupport.appendingPathComponent("Repositories"),
                                    to: support.appendingPathComponent("Repositories"))
            let keys = copyMissing(from: sourceSupport.appendingPathComponent("Keys"),
                                   to: support.appendingPathComponent("Keys"))
            if let items = try? fm.contentsOfDirectory(atPath: sourceSupport.path) {
                for name in items where name.hasPrefix("es.fsnot.project-settings") {
                    let dst = support.appendingPathComponent(name)
                    if !fm.fileExists(atPath: dst.path) {
                        try? fm.copyItem(at: sourceSupport.appendingPathComponent(name), to: dst)
                    }
                }
            }
            if repos > 0 { summary.append("\(repos) git repositories") }
            if keys > 0 { summary.append("\(keys) SSH keys") }
        }

        defaults.set(true, forKey: gitPendingKey)
        defaults.set(summary, forKey: summaryKey)
        defaults.set(true, forKey: doneKey)
    }

    /// Notes folder used by the original app, as a plain path this build can open
    private static func storagePath(from original: [String: Any], source: URL) -> String? {
        let fm = FileManager.default
        let type = (original["storageType"] as? Int) ?? StorageType.none.rawValue

        switch StorageType(rawValue: type) {
        case .iCloudDrive?:
            let cloud = home.appendingPathComponent("Library/Mobile Documents/iCloud~co~fluder~fsnotes/Documents", isDirectory: true)
            return fm.fileExists(atPath: cloud.path) ? cloud.path : nil
        case .custom?:
            if let path = original["storageUrl"] as? String, fm.fileExists(atPath: path) { return path }
            return nil
        case .local?:
            let documents = source.appendingPathComponent("Documents", isDirectory: true)
            return fm.fileExists(atPath: documents.path) ? documents.path : nil
        default:
            return nil
        }
    }

    /// Fully resolved path (`realpath`: unlike Foundation it keeps /private/tmp, /private/var)
    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @discardableResult
    private static func copyMissing(from src: URL, to dst: URL) -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: src.path) else { return 0 }
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)

        var count = 0
        for name in items where name != "tmp" && !name.hasPrefix(".") {
            let target = dst.appendingPathComponent(name)
            guard !fm.fileExists(atPath: target.path) else { continue }
            if (try? fm.copyItem(at: src.appendingPathComponent(name), to: target)) != nil {
                count += 1
            }
        }
        return count
    }

    /// After the notes are loaded: rebuild per-folder git settings (the original keeps them
    /// in iCloud key-value storage, which only its own signed build can read), then report.
    static func finishAfterLaunch() {
        guard defaults.bool(forKey: gitPendingKey) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            defaults.set(false, forKey: gitPendingKey)

            var gitFolders = [String]()
            for project in Storage.shared().getProjects() where project.importLegacyGitSettings() {
                gitFolders.append(project.label)
            }

            var lines = (defaults.stringArray(forKey: summaryKey) ?? [])
            defaults.removeObject(forKey: summaryKey)
            if !gitFolders.isEmpty {
                lines.append("git backup for: " + gitFolders.joined(separator: ", "))
            }
            guard !lines.isEmpty else { return }

            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Settings imported from FSNotes", comment: "")
            var text = lines.map { "• " + $0 }.joined(separator: "\n")
            if !gitFolders.isEmpty {
                text += "\n\n" + NSLocalizedString("If your SSH key has a passphrase, enter it again in Settings → Git (the original app keeps it in iCloud, out of reach for this build).", comment: "")
            }
            alert.informativeText = text
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
