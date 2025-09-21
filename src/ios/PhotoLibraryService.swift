import Photos
import UIKit
import Foundation
import MobileCoreServices
import UniformTypeIdentifiers

extension PHAsset {

    // Returns original file name, useful for photos synced with iTunes
    var originalFileName: String? {
        var result: String?

        // This technique is slow
        if #available(iOS 9.0, *) {
            let resources = PHAssetResource.assetResources(for: self)
            if let resource = resources.first {
                result = resource.originalFilename
            }
        }

        return result
    }

    var fileName: String? {
        return self.value(forKey: "filename") as? String
    }

}

final class PhotoLibraryService {

    let fetchOptions: PHFetchOptions!
    let thumbnailRequestOptions: PHImageRequestOptions!
    let imageRequestOptions: PHImageRequestOptions!
    let dateFormatter: DateFormatter!
    let cachingImageManager: PHCachingImageManager!

    let contentMode = PHImageContentMode.aspectFill // AspectFit: can be smaller, AspectFill - can be larger. TODO: resize to exact size

    var cacheActive = false

    var photo : UIImage? = nil
    var images : [NSDictionary] = [NSDictionary]()

    let mimeTypes = [
        "flv":  "video/x-flv",
        "mp4":  "video/mp4",
        "m3u8":	"application/x-mpegURL",
        "ts":   "video/MP2T",
        "3gp":	"video/3gpp",
        "mov":	"video/quicktime",
        "avi":	"video/x-msvideo",
        "wmv":	"video/x-ms-wmv",
        "gif":  "image/gif",
        "jpg":  "image/jpeg",
        "jpeg": "image/jpeg",
        "png":  "image/png",
        "tiff": "image/tiff",
        "tif":  "image/tiff"
    ]

    static let PERMISSION_ERROR = "Permission Denial: This application is not allowed to access Photo data."

    let dataURLPattern = try! NSRegularExpression(pattern: "^data:.+?;base64,", options: NSRegularExpression.Options(rawValue: 0))

    let assetCollectionTypes = [PHAssetCollectionType.album, PHAssetCollectionType.smartAlbum/*, PHAssetCollectionType.moment*/]

    fileprivate init() {
        fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        //fetchOptions.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
        if #available(iOS 9.0, *) {
            fetchOptions.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced, .typeCloudShared]
        }

        thumbnailRequestOptions = PHImageRequestOptions()
        thumbnailRequestOptions.isSynchronous = false
        thumbnailRequestOptions.resizeMode = .exact
        thumbnailRequestOptions.deliveryMode = .highQualityFormat
        thumbnailRequestOptions.version = .current
        thumbnailRequestOptions.isNetworkAccessAllowed = true

        imageRequestOptions = PHImageRequestOptions()
        imageRequestOptions.isSynchronous = false
        imageRequestOptions.resizeMode = .exact
        imageRequestOptions.deliveryMode = .highQualityFormat
        imageRequestOptions.version = .current
        imageRequestOptions.isNetworkAccessAllowed = true

        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"

        cachingImageManager = PHCachingImageManager()
    }

    class var instance: PhotoLibraryService {

        struct SingletonWrapper {
            static let singleton = PhotoLibraryService()
        }

        return SingletonWrapper.singleton

    }

    func getPhotosFromAlbum(_ albumTitle: String) -> [NSDictionary] {

        self.images = [NSDictionary]()

        var fetchedCollection: PHAssetCollection?

        for assetCollectionType in assetCollectionTypes {

            let fetchResult = PHAssetCollection.fetchAssetCollections(with: assetCollectionType, subtype: .any, options: nil)

            fetchResult.enumerateObjects({ (assetCollection: PHAssetCollection, index, stop) in
                if assetCollection.localizedTitle == albumTitle {
                    fetchedCollection = assetCollection
                    stop.pointee = true
                }
            });

            if fetchedCollection != nil {
                print("Found album")
                break
            }
        }

        let photoAssets = PHAsset.fetchAssets(in: fetchedCollection ?? PHAssetCollection(), options: nil) as? PHFetchResult<AnyObject>

        photoAssets?.enumerateObjects{(object: AnyObject!,
                                       count: Int,
                                       stop: UnsafeMutablePointer<ObjCBool>) in

            if object is PHAsset{
                let asset = object as! PHAsset
                print("Asset")
                print(asset)

                let semaphore = DispatchSemaphore(value: 0)

                let libraryItem = self.assetToLibraryItem(asset: asset, useOriginalFileNames: false, includeAlbumData: false);

                self.getCompleteInfo(libraryItem, completion: { (fullPath) in
                    libraryItem["filePath"] = fullPath
                    semaphore.signal()
                })

                semaphore.wait()

                self.images.append(libraryItem)

                //                let imageSize = CGSize(width: asset.pixelWidth,
                //                                       height: asset.pixelHeight)
                //
                //                /* For faster performance, and maybe degraded image */
                //                let options = PHImageRequestOptions()
                //                options.deliveryMode = .fastFormat
                //                options.isSynchronous = true
                //
                //                imageManager.requestImage(for: asset,
                //                                          targetSize: imageSize,
                //                                          contentMode: .aspectFill,
                //                                          options: options,
                //                                          resultHandler: {
                //                                            (image, info) -> Void in
                //                                            self.photo = image!
                //                                            /* The image is now available to us */
                //                                            self.addImgToArray(uploadImage: self.photo!)
                //                                            print("enum for image, This is number 2")
                //
                //                })

            }
        }

        return self.images;
    }

    func getLibrary(_ options: PhotoLibraryGetLibraryOptions, completion: @escaping (_ result: [NSDictionary], _ chunkNum: Int, _ isLastChunk: Bool) -> Void) {

        if(options.includeCloudData == false) {
            if #available(iOS 9.0, *) {
                // remove iCloud source type
                fetchOptions.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
            }
        }

        // let fetchResult = PHAsset.fetchAssets(with: .image, options: self.fetchOptions)
        if(options.includeImages == true && options.includeVideos == true) {
            fetchOptions.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d",
                                                 PHAssetMediaType.image.rawValue,
                                                 PHAssetMediaType.video.rawValue)
        }
        else {
            if(options.includeImages == true) {
                fetchOptions.predicate = NSPredicate(format: "mediaType == %d",
                                                     PHAssetMediaType.image.rawValue)
            }
            else if(options.includeVideos == true) {
                fetchOptions.predicate = NSPredicate(format: "mediaType == %d",
                                                     PHAssetMediaType.video.rawValue)
            }
        }

        let fetchResult = PHAsset.fetchAssets(with: fetchOptions)



	// TODO: do not restart caching on multiple calls
//        if fetchResult.count > 0 {
//
//            var assets = [PHAsset]()
//            fetchResult.enumerateObjects({(asset, index, stop) in
//                assets.append(asset)
//            })
//
//            self.stopCaching()
//            self.cachingImageManager.startCachingImages(for: assets, targetSize: CGSize(width: options.thumbnailWidth, height: options.thumbnailHeight), contentMode: self.contentMode, options: self.imageRequestOptions)
//            self.cacheActive = true
//        }

        var chunk = [NSDictionary]()
        var chunkStartTime = NSDate()
        var chunkNum = 0

        fetchResult.enumerateObjects({ (asset: PHAsset, index, stop) in

            if (options.maxItems > 0 && index + 1 > options.maxItems) {
                completion(chunk, chunkNum, true)
                return
            }

            let libraryItem = self.assetToLibraryItem(asset: asset, useOriginalFileNames: options.useOriginalFileNames, includeAlbumData: options.includeAlbumData)

            chunk.append(libraryItem)

            self.getCompleteInfo(libraryItem, completion: { (fullPath) in

                libraryItem["filePath"] = fullPath

                if index == fetchResult.count - 1 { // Last item
                    completion(chunk, chunkNum, true)
                } else if (options.itemsInChunk > 0 && chunk.count == options.itemsInChunk) ||
                    (options.chunkTimeSec > 0 && abs(chunkStartTime.timeIntervalSinceNow) >= options.chunkTimeSec) {
                    completion(chunk, chunkNum, false)
                    chunkNum += 1
                    chunk = [NSDictionary]()
                    chunkStartTime = NSDate()
                }
            })
        })
    }



    func mimeTypeForPath(path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()

        if !ext.isEmpty {
            if #available(iOS 14.0, *) {
                if let type = UTType(filenameExtension: ext),
                   let mimeType = type.preferredMIMEType {
                    return mimeType
                }
            } else {
                if #available(iOS 15.0, *) {
                    // Runtime will never hit this branch because iOS 15+ satisfies the earlier availability check.
                } else if let uti = UTTypeCreatePreferredIdentifierForTag("public.filename-extension" as CFString, ext as CFString, nil)?.takeRetainedValue(),
                          let mime = UTTypeCopyPreferredTagWithClass(uti, "public.mime-type" as CFString)?.takeRetainedValue() {
                    return mime as String
                }
            }

            if let fallbackMime = mimeTypes[ext] {
                return fallbackMime
            }
        }

        return "application/octet-stream"
    }


    private func requestImageData(for asset: PHAsset,
                                  options: PHImageRequestOptions?,
                                  resultHandler: @escaping (_ data: Data?, _ dataUTI: String?, _ info: [AnyHashable: Any]?) -> Void) {
        if #available(iOS 13.0, *) {
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, dataUTI, _, info in
                resultHandler(data, dataUTI, info)
            }
        } else {
            PHImageManager.default().requestImageData(for: asset, options: options) { data, dataUTI, _, info in
                resultHandler(data, dataUTI, info)
            }
        }
    }


    func getCompleteInfo(_ libraryItem: NSDictionary, completion: @escaping (_ fullPath: String?) -> Void) {


        let ident = libraryItem.object(forKey: "id") as! String
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [ident], options: self.fetchOptions)
        if fetchResult.count == 0 {
            completion(nil)
            return
        }

        let mime_type = libraryItem.object(forKey: "mimeType") as! String
        let mediaType = mime_type.components(separatedBy: "/").first


        fetchResult.enumerateObjects({
            (obj: AnyObject, idx: Int, stop: UnsafeMutablePointer<ObjCBool>) -> Void in
            let asset = obj as! PHAsset

            if(mediaType == "image") {
                self.requestImageData(for: asset, options: self.imageRequestOptions) {
                    (imageData: Data?, _ dataUTI: String?, info: [AnyHashable: Any]?) in

                    if(imageData == nil) {
                        completion(nil)
                    }
                    else {
                        if #available(iOS 13.0, *) {
                            let file_url:NSString = (info?["PHImageFileUTIKey"] as? NSString)!
                            completion(file_url as String)
                        } else {
                            let file_url:URL = info!["PHImageFileURLKey"] as! URL
                            //let mime_type = self.mimeTypes[file_url.pathExtension.lowercased()]!
                            completion(file_url.relativePath)
                        }
                    }
                }
            }
            else if(mediaType == "video") {

                PHImageManager.default().requestAVAsset(forVideo: asset, options: nil, resultHandler: { (avAsset: AVAsset?, avAudioMix: AVAudioMix?, info: [AnyHashable : Any]?) in

                    if( avAsset is AVURLAsset ) {
                        let video_asset = avAsset as! AVURLAsset
                        let url = URL(fileURLWithPath: video_asset.url.relativePath)
                        completion(url.relativePath)
                    }
                    else if(avAsset is AVComposition) {
                        let token = info?["PHImageFileSandboxExtensionTokenKey"] as! String
                        let path = token.components(separatedBy: ";").last
                        completion(path)
                    }
                })
            }
            else if(mediaType == "audio") {
                // TODO:
                completion(nil)
            }
            else {
                completion(nil) // unknown
            }
        })
    }


    private func assetToLibraryItem(asset: PHAsset, useOriginalFileNames: Bool, includeAlbumData: Bool) -> NSMutableDictionary {
        let libraryItem = NSMutableDictionary()

        libraryItem["id"] = asset.localIdentifier
        libraryItem["fileName"] = useOriginalFileNames ? asset.originalFileName : asset.fileName // originalFilename is much slower
        libraryItem["width"] = asset.pixelWidth
        libraryItem["height"] = asset.pixelHeight

        let fname = libraryItem["fileName"] as! String
        libraryItem["mimeType"] = self.mimeTypeForPath(path: fname)

        libraryItem["creationDate"] = self.dateFormatter.string(from: asset.creationDate!)
        if let location = asset.location {
            libraryItem["latitude"] = location.coordinate.latitude
            libraryItem["longitude"] = location.coordinate.longitude
        }


        if includeAlbumData {
            // This is pretty slow, use only when needed
            var assetCollectionIds = [String]()
            for assetCollectionType in self.assetCollectionTypes {
                let albumsOfAsset = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: assetCollectionType, options: nil)
                albumsOfAsset.enumerateObjects({ (assetCollection: PHAssetCollection, index, stop) in
                    assetCollectionIds.append(assetCollection.localIdentifier)
                })
            }
            libraryItem["albumIds"] = assetCollectionIds
        }

        return libraryItem
    }

    func getAlbums() -> [NSDictionary] {

        var result = [NSDictionary]()

        for assetCollectionType in assetCollectionTypes {

            let fetchResult = PHAssetCollection.fetchAssetCollections(with: assetCollectionType, subtype: .any, options: nil)

            fetchResult.enumerateObjects({ (assetCollection: PHAssetCollection, index, stop) in

                let albumItem = NSMutableDictionary()

                albumItem["id"] = assetCollection.localIdentifier
                albumItem["title"] = assetCollection.localizedTitle

                result.append(albumItem)

            });

        }

        return result;

    }

    func getThumbnail(_ photoId: String, thumbnailWidth: Int, thumbnailHeight: Int, quality: Float, completion: @escaping (_ result: PictureData?) -> Void) {

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [photoId], options: self.fetchOptions)

        if fetchResult.count == 0 {
            completion(nil)
            return
        }

        fetchResult.enumerateObjects({
            (obj: AnyObject, idx: Int, stop: UnsafeMutablePointer<ObjCBool>) -> Void in

            let asset = obj as! PHAsset

            self.cachingImageManager.requestImage(for: asset, targetSize: CGSize(width: thumbnailWidth, height: thumbnailHeight), contentMode: self.contentMode, options: self.thumbnailRequestOptions) {
                (image: UIImage?, imageInfo: [AnyHashable: Any]?) in

                guard let image = image else {
                    completion(nil)
                    return
                }

                let imageData = PhotoLibraryService.image2PictureData(image, quality: quality)

                completion(imageData)
            }
        })

    }

    func getPhoto(_ photoId: String, completion: @escaping (_ result: PictureData?) -> Void) {

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [photoId], options: self.fetchOptions)

        if fetchResult.count == 0 {
            completion(nil)
            return
        }

        fetchResult.enumerateObjects({
            (obj: AnyObject, idx: Int, stop: UnsafeMutablePointer<ObjCBool>) -> Void in

            let asset = obj as! PHAsset

            self.requestImageData(for: asset, options: self.imageRequestOptions) {
                (imageData: Data?, _ dataUTI: String?, _ info: [AnyHashable: Any]?) in

                guard let image = imageData != nil ? UIImage(data: imageData!) : nil else {
                    completion(nil)
                    return
                }

                let imageData = PhotoLibraryService.image2PictureData(image, quality: 1.0)

                completion(imageData)
            }
        })
    }


    func getLibraryItem(_ itemId: String, mimeType: String, completion: @escaping (_ base64: String?) -> Void) {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [itemId], options: self.fetchOptions)
        if fetchResult.count == 0 {
            completion(nil)
            return
        }

        // TODO: data should be returned as chunks, even for pics.
        // a massive data object might increase RAM usage too much, and iOS will then kill the app.
        fetchResult.enumerateObjects({
            (obj: AnyObject, idx: Int, stop: UnsafeMutablePointer<ObjCBool>) -> Void in
            let asset = obj as! PHAsset

            let mediaType = mimeType.components(separatedBy: "/")[0]

            if(mediaType == "image") {
                self.requestImageData(for: asset, options: self.imageRequestOptions) {
                    (imageData: Data?, _ dataUTI: String?, _ info: [AnyHashable: Any]?) in

                    if(imageData == nil) {
                        completion(nil)
                    }
                    else {
//                        let file_url:URL = info!["PHImageFileURLKey"] as! URL
//                        let mime_type = self.mimeTypes[file_url.pathExtension.lowercased()]
                        completion(imageData!.base64EncodedString())
                    }
                }
            }
            else if(mediaType == "video") {

                PHImageManager.default().requestAVAsset(forVideo: asset, options: nil, resultHandler: { (avAsset: AVAsset?, avAudioMix: AVAudioMix?, info: [AnyHashable : Any]?) in

                    let video_asset = avAsset as! AVURLAsset
                    let url = URL(fileURLWithPath: video_asset.url.relativePath)

                    do {
                        let video_data = try Data(contentsOf: url)
                        let video_base64 = video_data.base64EncodedString()
//                        let mime_type = self.mimeTypes[url.pathExtension.lowercased()]
                        completion(video_base64)
                    }
                    catch _ {
                        completion(nil)
                    }
                })
            }
            else if(mediaType == "audio") {
                // TODO:
                completion(nil)
            }
            else {
                completion(nil) // unknown
            }

        })
    }


    func getVideo(_ videoId: String, completion: @escaping (_ result: PictureData?) -> Void) {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [videoId], options: self.fetchOptions)
        if fetchResult.count == 0 {
            completion(nil)
            return
        }

        fetchResult.enumerateObjects({
            (obj: AnyObject, idx: Int, stop: UnsafeMutablePointer<ObjCBool>) -> Void in

            let asset = obj as! PHAsset


            PHImageManager.default().requestAVAsset(forVideo: asset, options: nil, resultHandler: { (avAsset: AVAsset?, avAudioMix: AVAudioMix?, info: [AnyHashable : Any]?) in

                let video_asset = avAsset as! AVURLAsset
                let url = URL(fileURLWithPath: video_asset.url.relativePath)

                do {
                    let video_data = try Data(contentsOf: url)
                    let pic_data = PictureData(data: video_data, mimeType: "video/quicktime") // TODO: get mime from info dic ?
                    completion(pic_data)
                }
                catch _ {
                    completion(nil)
                }
            })
        })
    }


    func stopCaching() {

        if self.cacheActive {
            self.cachingImageManager.stopCachingImagesForAllAssets()
            self.cacheActive = false
        }

    }

    func requestAuthorization(_ success: @escaping () -> Void, failure: @escaping (_ err: String) -> Void ) {

        let status = PHPhotoLibrary.authorizationStatus()

        if status == .authorized {
            success()
            return
        }

        if status == .notDetermined {
            // Ask for permission
            PHPhotoLibrary.requestAuthorization() { (status) -> Void in
                switch status {
                case .authorized:
                    success()
                default:
                    failure("requestAuthorization denied by user")
                }
            }
            return
        }

        // Permission was manually denied by user, open settings screen
        let settingsUrl = URL(string: UIApplication.openSettingsURLString)
        if let url = settingsUrl {
            if #available(iOS 10.0, *) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            } else {
                UIApplication.shared.openURL(url)
            }
            // TODO: run callback only when return ?
            // Do not call success, as the app will be restarted when user changes permission
        } else {
            failure("could not open settings url")
        }

    }

    // Save image data or file into Photos and add to album using PHPhotoLibrary
    func saveImage(_ url: String, album: String, completion: @escaping (_ libraryItem: NSDictionary?, _ error: String?)->Void) {

        func ensureAlbum(_ name: String, cb: @escaping (PHAssetCollection?, String?) -> Void) {
            if let existing = PhotoLibraryService.getPhotoAlbum(name) { cb(existing, nil) }
            else { PhotoLibraryService.createPhotoAlbum(name, completion: cb) }
        }

        ensureAlbum(album) { (collection, err) in
            guard let collection = collection else {
                completion(nil, err)
                return
            }

            var placeholder: PHObjectPlaceholder?

            PHPhotoLibrary.shared().performChanges({
                if url.hasPrefix("data:") {
                    // Data URL path (including GIF). Use addResource to preserve original bytes.
                    if let data = try? self.getDataFromURL(url) {
                        let request = PHAssetCreationRequest.forAsset()
                        let opts = PHAssetResourceCreationOptions()
                        // Try to infer UTI from data URL mime type
                        if url.lowercased().contains("image/gif") {
                            if #available(iOS 14.0, *) {
                                opts.uniformTypeIdentifier = UTType.gif.identifier
                            } else {
                                opts.uniformTypeIdentifier = "com.compuserve.gif"
                            }
                        }
                        request.addResource(with: .photo, data: data, options: opts)
                        placeholder = request.placeholderForCreatedAsset
                    }
                } else {
                    var maybeURL = URL(string: url)
                    if maybeURL == nil,
                       let encoded = url.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) {
                        maybeURL = URL(string: encoded)
                    }

                    if let fileURL = maybeURL {
                        // File URL path. Prefer creation from file to keep type.
                        let creation = PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                        placeholder = creation?.placeholderForCreatedAsset
                    } else {
                        // Treat as local file path fallback.
                        let fileURL = URL(fileURLWithPath: url)
                        let creation = PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                        placeholder = creation?.placeholderForCreatedAsset
                    }

                    if placeholder == nil,
                       let data = try? self.getDataFromURL(url) {
                        let request = PHAssetCreationRequest.forAsset()
                        request.addResource(with: .photo, data: data, options: nil)
                        placeholder = request.placeholderForCreatedAsset
                    }
                }

                if let ph = placeholder, let change = PHAssetCollectionChangeRequest(for: collection) {
                    change.addAssets([ph] as NSArray)
                }
            }, completionHandler: { success, error in
                guard success, let ph = placeholder else {
                    completion(nil, "Could not save image: \(String(describing: error))")
                    return
                }
                let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [ph.localIdentifier], options: nil)
                if let asset = fetch.firstObject {
                    let item = self.assetToLibraryItem(asset: asset, useOriginalFileNames: false, includeAlbumData: true)
                    completion(item, nil)
                } else {
                    completion(nil, "Saved image, but could not fetch asset")
                }
            })
        }
    }

    func saveVideo(_ url: String, album: String, completion: @escaping (_ libraryItem: NSDictionary?, _ error: String?)->Void) {

        func ensureAlbum(_ name: String, cb: @escaping (PHAssetCollection?, String?) -> Void) {
            if let existing = PhotoLibraryService.getPhotoAlbum(name) { cb(existing, nil) }
            else { PhotoLibraryService.createPhotoAlbum(name, completion: cb) }
        }

        // Resolve to a file URL. If it's a data: URL -> write to a temp file.
        func resolveVideoURL(_ input: String) -> URL? {
            if input.hasPrefix("data:") {
                if let data = try? self.getDataFromURL(input) {
                    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
                    do { try data.write(to: tmp, options: .atomic) } catch { return nil }
                    return tmp
                }
                return nil
            }
            return URL(string: input) ?? URL(fileURLWithPath: input)
        }

        guard let fileURL = resolveVideoURL(url) else {
            completion(nil, "Could not parse video URL")
            return
        }

        ensureAlbum(album) { (collection, err) in
            guard let collection = collection else {
                completion(nil, err)
                return
            }

            var placeholder: PHObjectPlaceholder?
            PHPhotoLibrary.shared().performChanges({
                if let creation = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: fileURL) {
                    placeholder = creation.placeholderForCreatedAsset
                    if let ph = placeholder, let change = PHAssetCollectionChangeRequest(for: collection) {
                        change.addAssets([ph] as NSArray)
                    }
                }
            }, completionHandler: { success, error in
                guard success, let ph = placeholder else {
                    completion(nil, "Could not save video: \(String(describing: error))")
                    return
                }
                let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [ph.localIdentifier], options: nil)
                if let asset = fetch.firstObject {
                    let item = self.assetToLibraryItem(asset: asset, useOriginalFileNames: false, includeAlbumData: true)
                    completion(item, nil)
                } else {
                    completion(nil, "Saved video, but could not fetch asset")
                }
            })
        }
    }

    struct PictureData {
        var data: Data
        var mimeType: String
    }

    // TODO: currently seems useless
    enum PhotoLibraryError: Error, CustomStringConvertible {
        case error(description: String)

        var description: String {
            switch self {
            case .error(let description): return description
            }
        }
    }

    fileprivate func getDataFromURL(_ url: String) throws -> Data {
        if url.hasPrefix("data:") {

            guard let match = self.dataURLPattern.firstMatch(in: url, options: NSRegularExpression.MatchingOptions(rawValue: 0), range: NSMakeRange(0, url.count)) else { // TODO: firstMatchInString seems to be slow for unknown reason
                throw PhotoLibraryError.error(description: "The dataURL could not be parsed")
            }
            let dataPos = match.range(at: 0).length
            let base64 = (url as NSString).substring(from: dataPos)
            guard let decoded = Data(base64Encoded: base64, options: NSData.Base64DecodingOptions(rawValue: 0)) else {
                throw PhotoLibraryError.error(description: "The dataURL could not be decoded")
            }

            return decoded

        } else {

            guard let nsURL = URL(string: url) else {
                throw PhotoLibraryError.error(description: "The url could not be decoded: \(url)")
            }
            guard let fileContent = try? Data(contentsOf: nsURL) else {
                throw PhotoLibraryError.error(description: "The url could not be read: \(url)")
            }

            return fileContent

        }
    }

    // Removed deprecated ALAssets-based album placement helper

    fileprivate static func image2PictureData(_ image: UIImage, quality: Float) -> PictureData? {
        //        This returns raw data, but mime type is unknown. Anyway, crodova performs base64 for messageAsArrayBuffer, so there's no performance gain visible
        //        let provider: CGDataProvider = CGImageGetDataProvider(image.CGImage)!
        //        let data = CGDataProviderCopyData(provider)
        //        return data;

        var data: Data?
        var mimeType: String?

        if (imageHasAlpha(image)){
            data = image.pngData()
            mimeType = data != nil ? "image/png" : nil
        } else {
            data = image.jpegData(compressionQuality: CGFloat(quality))
            mimeType = data != nil ? "image/jpeg" : nil
        }

        if data != nil && mimeType != nil {
            return PictureData(data: data!, mimeType: mimeType!)
        }
        return nil
    }

    fileprivate static func imageHasAlpha(_ image: UIImage) -> Bool {
        let alphaInfo = (image.cgImage)?.alphaInfo
        return alphaInfo == .first || alphaInfo == .last || alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast
    }

    fileprivate static func getPhotoAlbum(_ album: String) -> PHAssetCollection? {

        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", album)
        let fetchResult = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: fetchOptions)
        guard let photoAlbum = fetchResult.firstObject else {
            return nil
        }

        return photoAlbum

    }

    fileprivate static func createPhotoAlbum(_ album: String, completion: @escaping (_ photoAlbum: PHAssetCollection?, _ error: String?)->()) {

        var albumPlaceholder: PHObjectPlaceholder?

        PHPhotoLibrary.shared().performChanges({

            let createAlbumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: album)
            albumPlaceholder = createAlbumRequest.placeholderForCreatedAssetCollection

        }) { success, error in

            guard let placeholder = albumPlaceholder else {
                completion(nil, "Album placeholder is nil")
                return
            }

            let fetchResult = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [placeholder.localIdentifier], options: nil)

            guard let photoAlbum = fetchResult.firstObject else {
                completion(nil, "FetchResult has no PHAssetCollection")
                return
            }

            if success {
                completion(photoAlbum, nil)
            }
            else {
                completion(nil, error?.localizedDescription ?? "Unknown error")
            }
        }
    }

    // Removed deprecated ALAssets album enumeration helper

}
