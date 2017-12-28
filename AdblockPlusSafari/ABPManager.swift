/*
 * This file is part of Adblock Plus <https://adblockplus.org/>,
 * Copyright (C) 2006-present eyeo GmbH
 *
 * Adblock Plus is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 3 as
 * published by the Free Software Foundation.
 *
 * Adblock Plus is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Adblock Plus.  If not, see <http://www.gnu.org/licenses/>.
 */

import RxCocoa
import RxSwift

/// KVO keys.
enum ABPState: String {
    case filterLists
    case reloading
}

/// Shared instance that contains the active Adblock Plus instance.
/// This class holds the operations that were previously coupled to the Objective-C app delegate.
/// It also attempts to consolidate state variables essential to the app's operation.
class ABPManager: NSObject {
    var bag: DisposeBag!

    /// Reloading will not happen when this value is true.
    var disableReloading = false

    /// Performs operations for updating filter lists.
    @objc var filterListsUpdater: FilterListsUpdater?

    /// For testing reloading KVO.
    var reloadingKeyValue: Int?

    /// Active instance of Adblock Plus. It is dynamic to support KVO.
    @objc dynamic var adblockPlus: AdblockPlusExtras! {
        /// Add kvo observers.
        didSet {
            setupKVO()
        }
    }

    /// This is a unique token (Int) that identifies a request to run in the background.
    var backgroundTaskIdentifier: UIBackgroundTaskIdentifier? {
        /// End the existing task before setting a new one.
        willSet {
            if backgroundTaskIdentifier != UIBackgroundTaskInvalid {
                if let uwBgTaskID = backgroundTaskIdentifier {
                    UIApplication.shared.endBackgroundTask(uwBgTaskID)
                }
            }
        }
    }

    private static var privateSharedInstance: ABPManager?
    private static let keyPaths: [ABPState] = [.filterLists, .reloading]
    private var firstUpdateTriggered: Bool = false
    private var backgroundFetches = [[String: Any]]()

    /// Destroy the shared instance in memory.
    class func destroy() {
        privateSharedInstance = nil
    }

    /// Access the shared instance.
    @objc class func sharedInstance() -> ABPManager {
        guard let shared = privateSharedInstance else {
            dLog("machen neu", date: "2017-Dec-27")
            privateSharedInstance = ABPManager()
            return privateSharedInstance!
        }
        return shared
    }

    /// Setup an initial Adblock Plus instance.
    override init() {
        dLog("🐮", date: "2017-Dec-20")
        super.init()
        defer {
            adblockPlus = AdblockPlusExtras()
            filterListsUpdater = FilterListsUpdater()
        }
    }

    /// Cleanup Adblock Plus instance and observers.
    deinit {
        bag = nil
        adblockPlus = nil
    }

    // ------------------------------------------------------------
    // MARK: - Objective-C Bridging -
    // ------------------------------------------------------------

    /// During the transition to Swift, filter lists previously held in Objective-C data structures
    /// will be made available in native Swift.
    func filterLists() -> [FilterList]
    {
        var result = [FilterList]()
        for key in adblockPlus.filterLists.keys {
            let converted = FilterList(withName: key,
                                       fromDictionary: adblockPlus.filterLists[key])
            result.append(converted!)
        }
        return result
    }

    /// Write the filter lists back to Objective-C.
    /// It is to be called with the lists to be saved.
    func saveFilterLists(_ lists: [FilterList])
    {
        var converted = [String: [String: Any]]()
        for list in lists {
            if let name = list.name {
                converted[name] = list.toDictionary()
            }
        }
        adblockPlus.filterLists = converted
    }

    /// Remove a filter list and save the results to the Objective-C side.
    func removeFilterList(_ name: String?)
    {
        guard name != nil else { return }
        saveFilterLists(filterLists().filter { $0.name != name })
    }

    /// Set updating on all filter lists to be false.
    /// DZ: Are the changes saved using var list?
    func setNotUpdating(forNames: [FilterListName])
    {
        let lists = filterLists()
        var newLists = [FilterList]()
        for var list in lists {
            list.updating = false
            newLists.append(list)
        }
        saveFilterLists(newLists)
    }

    func downloadTasks() -> [URLSessionDownloadTask]
    {
        var result = [URLSessionDownloadTask]()
        return result
    }

    // ------------------------------------------------------------
    // MARK: - Foreground mode -
    // ------------------------------------------------------------

    /// When the app becomes active, if there are outdated filter lists, update them.
    func handleDidBecomeActive() {
        guard let updater = ABPManager.sharedInstance().filterListsUpdater else { return }
        adblockPlus.checkActivatedFlag()
        if !firstUpdateTriggered &&
           !adblockPlus.updating {
            let filterListNames: [String] = updater.outdatedFilterListNames()
            if filterListNames.count > 0 {
                updater.updateFilterLists(withNames: filterListNames,
                                          userTriggered: false)
                firstUpdateTriggered = true
            }
        }
    }

    // ------------------------------------------------------------
    // MARK: - Background mode -
    // ------------------------------------------------------------

    func handlePerformFetch(withCompletionHandler completion: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let updater = ABPManager.sharedInstance().filterListsUpdater else { return }
        let outdatedFilterListNames = updater.outdatedFilterListNames()
        if outdatedFilterListNames.count > 0 {
            var outdatedFilterLists = [String: Any]()
            for outdatedFilterListName in outdatedFilterListNames {
                outdatedFilterLists[outdatedFilterListName] = adblockPlus.filterLists[outdatedFilterListName]
            }
            updater.updateFilterLists(withNames: outdatedFilterListNames,
                                       userTriggered: false)
            backgroundFetches.append(["completion": completion,
                                      "filterLists": outdatedFilterLists,
                                      "startDate": Date()])
        } else {
            // No need to perform background refresh
            completion(UIBackgroundFetchResult.noData)
        }
    }

    /// Begin background tasks if filter lists are reloading.
    func handleDidEnterBackground() {
        if !adblockPlus.reloading {
            return
        }
        let expirationHandler: () -> Void = { [weak self] in
            self?.backgroundTaskIdentifier = UIBackgroundTaskInvalid
        }
        let app = UIApplication.shared
        backgroundTaskIdentifier = app.beginBackgroundTask(expirationHandler: expirationHandler)
    }

    /// Process events initiated by background URLSession requests.
    func handleEventsForBackgroundURLSession(identifier: String,
                                             completion: @escaping () -> Void) {
        whitelistedWebsites(forSessionID: identifier)
            .subscribe(onCompleted: {
                self.handleDidEnterBackground()
                completion()
            }).disposed(by: bag)
    }

    // ------------------------------------------------------------
    // MARK: - KVO -
    // ------------------------------------------------------------

    /// Subscribe to kvo updates.
    private func setupKVO() {
        bag = DisposeBag()
        let subs = [reloadingSubscription,
                    filterListsSubscription]
        _ = subs.map { $0().disposed(by: bag) }
    }

    /// Subscription of changes on reloading key.
    /// Reloading occurs when
    /// * Filter lists are configured or updated
    /// * Acceptable ads switch is changed
    /// * A website is added to, or deleted from, the whitelist, inside ABP
    /// * A website is whitelisted with the Safari action extension
    /// Note that instantiating an ABPManager shared instance within the subscription will cause an infinite loop.
    private func reloadingSubscription() -> Disposable {
        return adblockPlus.rx
            .observeWeakly(Bool.self,
                           ABPState.reloading.rawValue,
                           options: [.initial, .new])
            .subscribe(onNext: { reloading in
                guard let uwReloading = reloading else {
                    return
                }

                // Used for unit testing to verify that the reloading observer is active.
                self.reloadingKeyValue = uwReloading ? 1 : 0

                dLog("⛸️", date: "2017-Dec-26")
                ABPDebug.printFilterLists(self.filterLists())

                let invalidBgTask = (self.backgroundTaskIdentifier == UIBackgroundTaskInvalid)
                if self.backgroundTaskIdentifier != UIBackgroundTaskInvalid &&
                   !uwReloading {
                    self.backgroundTaskIdentifier = UIBackgroundTaskInvalid
                }
                if invalidBgTask && uwReloading && self.isBackground() {
                    let app = UIApplication.shared
                    self.backgroundTaskIdentifier = app.beginBackgroundTask(expirationHandler: { [weak self] in
                        self?.backgroundTaskIdentifier = UIBackgroundTaskInvalid
                    })
                }
            })
    }

    /// Determine if the app is in the background.
    /// The app is in the background when whitelisting through the Safari action extension.
    private func isBackground() -> Bool
    {
        let app = UIApplication.shared
        let isBackground = (app.applicationState != UIApplicationState.active)
        dLog("is background = \(isBackground)", date: "2017-Dec-26")
        return isBackground
    }

    /// Subscription of changes on filterLists key.
    private func filterListsSubscription() -> Disposable {
        return adblockPlus.rx
            .observeWeakly(NSDictionary.self,
                           ABPState.filterLists.rawValue,
                           options: [.initial, .new])
            .subscribe(onNext: { filterLists in
                guard filterLists != nil else {
                    return
                }
                self.checkFilterList()
            })
    }

    private func checkFilterList() {
        if adblockPlus.updating {
            for bgFetch in backgroundFetches {
                var updated = false
                let filterLists = bgFetch["filterLists"] as? [String: Any]
                if let uwFilterLists = filterLists {
                    for key in uwFilterLists.keys {
                        let filterList = uwFilterLists[key] as? [String: Any]
                        var lastUpdate: Date?
                        var currentLastUpdate: Date?
                        if let uwFilterList = filterList {
                            lastUpdate = uwFilterList["lastUpdate"] as? Date
                        }
                        if let uwFilterList = adblockPlus.filterLists[key] {
                            currentLastUpdate = uwFilterList["lastUpdate"] as? Date
                        }
                        updated = updated ||
                                  (lastUpdate == nil && currentLastUpdate != nil) ||
                                  ((currentLastUpdate != nil && lastUpdate != nil) && currentLastUpdate?.compare(lastUpdate!) == .orderedDescending)
                        if let uwCompletion = bgFetch["completion"] as? (UIBackgroundFetchResult) -> Void {
                            uwCompletion(updated ? UIBackgroundFetchResult.newData : UIBackgroundFetchResult.failed)
                        }
                    } // End for key
                }
                backgroundFetches = []
            } // End for bgFetch
        }
    }
}
