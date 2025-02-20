package com.terikon.cordova.photolibrary;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.util.Base64;
import android.webkit.WebResourceResponse;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.webkit.WebViewAssetLoader;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.CordovaPluginPathHandler;
import org.apache.cordova.CordovaResourceApi;
import org.apache.cordova.LOG;
import org.apache.cordova.PermissionHelper;
import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayInputStream;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;

/**
 * @noinspection CallToPrintStackTrace
 */
public class PhotoLibrary extends CordovaPlugin {
	private static final String TAG = PhotoLibrary.class.getSimpleName();

	public static final String PHOTO_LIBRARY_PROTOCOL = "cdvphotolibrary";

	public static final int DEFAULT_WIDTH = 512;
	public static final int DEFAULT_HEIGHT = 384;
	public static final double DEFAULT_QUALITY = 0.5;

	public static final String ACTION_GET_LIBRARY = "getLibrary";
	public static final String ACTION_GET_ALBUMS = "getAlbums";
	public static final String ACTION_GET_THUMBNAIL = "getThumbnail";
	public static final String ACTION_GET_PHOTO = "getPhoto";
	public static final String ACTION_STOP_CACHING = "stopCaching";
	public static final String ACTION_REQUEST_AUTHORIZATION = "requestAuthorization";
	public static final String ACTION_SAVE_IMAGE = "saveImage";
	public static final String ACTION_SAVE_VIDEO = "saveVideo";

	public CallbackContext callbackContext;
	private static final List<String> storageReadPermissions = new ArrayList<>();
	private static final List<String> storageWritePermissions = new ArrayList<>();
	private static final List<String> imageReadPermissions = new ArrayList<>();
	private static final List<String> imageWritePermissions = new ArrayList<>();
	private static final List<String> videoReadPermissions = new ArrayList<>();
	private static final List<String> videoWritePermissions = new ArrayList<>();

	static {
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
			imageReadPermissions.add(Manifest.permission.ACCESS_MEDIA_LOCATION);
		}

		if (android.os.Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {

			imageReadPermissions.add(Manifest.permission.READ_MEDIA_IMAGES);
			imageWritePermissions.add(Manifest.permission.READ_MEDIA_IMAGES);

			videoReadPermissions.add(Manifest.permission.READ_MEDIA_VIDEO);
			videoWritePermissions.add(Manifest.permission.READ_MEDIA_VIDEO);

		} else { //sdk < 33

			storageReadPermissions.add(Manifest.permission.READ_EXTERNAL_STORAGE);
			storageWritePermissions.addAll(storageReadPermissions);
			storageWritePermissions.add(Manifest.permission.WRITE_EXTERNAL_STORAGE);

			imageReadPermissions.addAll(storageReadPermissions);
			imageWritePermissions.addAll(imageReadPermissions);
			imageWritePermissions.addAll(storageWritePermissions);

			videoReadPermissions.addAll(storageReadPermissions);
			videoWritePermissions.addAll(videoReadPermissions);
			videoWritePermissions.addAll(storageWritePermissions);
		}
	}

	@Override
	protected void pluginInitialize() {
		super.pluginInitialize();

		service = PhotoLibraryService.getInstance();
		service.setResourceApi(webView.getResourceApi());

	}

	@Override
	public boolean execute(String action, final JSONArray args, final CallbackContext callbackContext) throws JSONException {

		this.callbackContext = callbackContext;

		try {

			if (ACTION_GET_LIBRARY.equals(action)) {
				getLibrary(args);
				return true;

			} else if (ACTION_GET_ALBUMS.equals(action)) {
				getAlbums();
				return true;

			} else if (ACTION_GET_THUMBNAIL.equals(action)) {
				getThumbnail(args);
				return true;

			} else if (ACTION_GET_PHOTO.equals(action)) {
				getPhoto(args);
				return true;

			} else if (ACTION_STOP_CACHING.equals(action)) {
				service.stopCaching();
				callbackContext.success();
				return true;

			} else if (ACTION_REQUEST_AUTHORIZATION.equals(action)) {
				requestAuthorization(args);
				return true;

			} else if (ACTION_SAVE_IMAGE.equals(action)) {
				saveImage(args);
				return true;

			} else if (ACTION_SAVE_VIDEO.equals(action)) {
				saveVideo(args);
				return true;

			}

			return false;

		} catch (Exception e) {
			e.printStackTrace();
			callbackContext.error(e.getMessage());
			return false;
		}
	}

	@Override
	public Uri remapUri(Uri uri) {

		if (!PHOTO_LIBRARY_PROTOCOL.equals(uri.getScheme())) {
			return null;
		}
		return toPluginUri(uri);

	}

	@Override
	public CordovaPluginPathHandler getPathHandler() {
		//Adapted from https://github.com/apache/cordova-android/issues/1361#issuecomment-978763603
		return new CordovaPluginPathHandler(new WebViewAssetLoader.PathHandler() {
			@Nullable
			@Override
			public WebResourceResponse handle(@NonNull String path) {
				LOG.d(TAG, "Path Handler " + path);
				//e.g. cdvphotolibrary/thumbnail/photoId=3112&width=512&height=384&quality=0.8
				if (path.startsWith(PHOTO_LIBRARY_PROTOCOL)) {
					path = path.replaceAll("^cdvphotolibrary/", "cdvphotolibrary://");
					path = path.replaceAll("thumbnail/", "thumbnail?");
					path = path.replaceAll("photo/", "photo?");

					Uri uri = Uri.parse(path);
					LOG.d(TAG, "URI " + uri);
					Uri remappedUri = remapUri(uri);
					LOG.d(TAG, "RemappedUri " + remappedUri);
					if (remappedUri != null) {
						try {
							CordovaResourceApi.OpenForReadResult result = handleOpenForRead(remappedUri);
							LOG.d(TAG, "Result " + result.inputStream.available());
							return new WebResourceResponse(result.mimeType, "utf-8", result.inputStream);
						} catch (IOException e) {
							LOG.e(TAG, "error open cdvphotolibrary resource " + e);
						}
					}
				}
				return null;
			}
		});
	}

	private void getLibrary(JSONArray args) {
		cordova.getThreadPool().execute(() -> {
			try {

				final JSONObject options = args.optJSONObject(0);
				final int itemsInChunk = options.getInt("itemsInChunk");
				final double chunkTimeSec = options.getDouble("chunkTimeSec");
				final boolean includeAlbumData = options.getBoolean("includeAlbumData");
				int limit = options.optInt("maxItems", -1);
				if (limit <= 0) { //0 wont return any result columns
					limit = -1;
				}

				if (isMissingPermissions(storageReadPermissions)) {
					callbackContext.error(PhotoLibraryService.PERMISSION_ERROR);
					return;
				}

				PhotoLibraryGetLibraryOptions getLibraryOptions = new PhotoLibraryGetLibraryOptions(itemsInChunk, chunkTimeSec, includeAlbumData, limit);

				service.getLibrary(getContext(), getLibraryOptions, (library, chunkNum, isLastChunk) -> {
					try {

						JSONObject result = createGetLibraryResult(library, chunkNum, isLastChunk);
						PluginResult pluginResult = new PluginResult(PluginResult.Status.OK, result);
						pluginResult.setKeepCallback(!isLastChunk);
						callbackContext.sendPluginResult(pluginResult);

					} catch (Exception e) {
						e.printStackTrace();
						callbackContext.error(e.getMessage());
					}
				});

			} catch (Exception e) {
				e.printStackTrace();
				callbackContext.error(e.getMessage());
			}
		});
	}

	private void getAlbums() {
		cordova.getThreadPool().execute(() -> {
			try {
				if (isMissingPermissions(storageReadPermissions)) {
					callbackContext.error(PhotoLibraryService.PERMISSION_ERROR);
					return;
				}

				ArrayList<JSONObject> albums = service.getAlbums(getContext());

				callbackContext.success(createGetAlbumsResult(albums));

			} catch (Exception e) {
				e.printStackTrace();
				callbackContext.error(e.getMessage());
			}
		});
	}

	private void getThumbnail(JSONArray args) {
		cordova.getThreadPool().execute(() -> {
			try {

				final String photoId = args.getString(0);
				final JSONObject options = args.optJSONObject(1);
				final int thumbnailWidth = options.getInt("thumbnailWidth");
				final int thumbnailHeight = options.getInt("thumbnailHeight");
				final double quality = options.getDouble("quality");

				if (isMissingPermissions(imageReadPermissions)) {
					callbackContext.error(PhotoLibraryService.PERMISSION_ERROR);
					return;
				}

				PhotoLibraryService.PictureData thumbnail = service.getThumbnail(getContext(), photoId, thumbnailWidth, thumbnailHeight, quality);
				callbackContext.sendPluginResult(createMultipartPluginResult(PluginResult.Status.OK, thumbnail));

			} catch (Exception e) {
				e.printStackTrace();
				callbackContext.error(e.getMessage());
			}
		});
	}

	private void getPhoto(JSONArray args) {

		cordova.getThreadPool().execute(() -> {
			try {

				final String photoId = args.getString(0);

				if (isMissingPermissions(imageReadPermissions)) {
					callbackContext.error(PhotoLibraryService.PERMISSION_ERROR);
					return;
				}

				PhotoLibraryService.PictureData photo = service.getPhoto(getContext(), photoId);
				callbackContext.sendPluginResult(createMultipartPluginResult(PluginResult.Status.OK, photo));

			} catch (Exception e) {
				e.printStackTrace();
				callbackContext.error(e.getMessage());
			}
		});
	}

	private void requestAuthorization(JSONArray args) {
		try {
			final JSONObject options = args.optJSONObject(0);
			final boolean read = options.getBoolean("read");
			final boolean write = options.getBoolean("write");
			final boolean requestImages = options.optBoolean("requestImages", true);
			final boolean requestVideos = options.optBoolean("requestVideos", true);
			final ArrayList<String> requiredPermissions = new ArrayList<>();
			if (requestImages) {
				if (read) requiredPermissions.addAll(imageReadPermissions);
				else requiredPermissions.addAll(imageWritePermissions);
			}

			if (requestVideos) {
				if (read) requiredPermissions.addAll(videoReadPermissions);
				else requiredPermissions.addAll(videoWritePermissions);
			}

			if (requiredPermissions.isEmpty()) {
				callbackContext.success();
				return;
			}

			if (isMissingPermissions(requiredPermissions)) {
				requestAuthorization(read, write);
			} else {
				callbackContext.success();
			}
		} catch (Exception e) {
			e.printStackTrace();
			callbackContext.error(e.getMessage());
		}
	}

	private void saveImage(JSONArray args) {
		cordova.getThreadPool().execute(() -> {
			try {

				final String url = args.getString(0);
				final String album = args.getString(1);

				if (isMissingPermissions(imageWritePermissions)) {
					callbackContext.error(PhotoLibraryService.PERMISSION_ERROR);
					return;
				}

				service.saveImage(getContext(), cordova, url, album, result -> callbackContext.success(result));

			} catch (Exception e) {
				e.printStackTrace();
				callbackContext.error(e.getMessage());
			}
		});
	}

	private void saveVideo(JSONArray args) {
		cordova.getThreadPool().execute(() -> {
			try {

				final String url = args.getString(0);
				final String album = args.getString(1);

				if (isMissingPermissions(videoWritePermissions)) {
					callbackContext.error(PhotoLibraryService.PERMISSION_ERROR);
					return;
				}

				service.saveVideo(getContext(), cordova, url, album);

				callbackContext.success();

			} catch (Exception e) {
				e.printStackTrace();
				callbackContext.error(e.getMessage());
			}
		});
	}

	@Override
	public CordovaResourceApi.OpenForReadResult handleOpenForRead(Uri uri) throws IOException {

		Uri origUri = fromPluginUri(uri);
		String host = origUri.getHost();
		String path = origUri.getPath();

		if (host == null || path == null) throw new FileNotFoundException("host unknown");

		boolean isThumbnail = host.equalsIgnoreCase("thumbnail") && path.isEmpty();
		boolean isPhoto = host.equalsIgnoreCase("photo") && path.isEmpty();

		if (!isThumbnail && !isPhoto) {
			throw new FileNotFoundException("URI not supported by PhotoLibrary");
		}

		String photoId = origUri.getQueryParameter("photoId");
		if (photoId == null || photoId.isEmpty()) {
			throw new FileNotFoundException("Missing 'photoId' query parameter");
		}

		if (isThumbnail) {

			String widthStr = origUri.getQueryParameter("width");
			int width;
			try {
				width = widthStr == null || widthStr.isEmpty() ? DEFAULT_WIDTH : Integer.parseInt(widthStr);
			} catch (NumberFormatException e) {
				throw new FileNotFoundException("Incorrect 'width' query parameter");
			}

			String heightStr = origUri.getQueryParameter("height");
			int height;
			try {
				height = heightStr == null || heightStr.isEmpty() ? DEFAULT_HEIGHT : Integer.parseInt(heightStr);
			} catch (NumberFormatException e) {
				throw new FileNotFoundException("Incorrect 'height' query parameter");
			}

			String qualityStr = origUri.getQueryParameter("quality");
			double quality;
			try {
				quality = qualityStr == null || qualityStr.isEmpty() ? DEFAULT_QUALITY : Double.parseDouble(qualityStr);
			} catch (NumberFormatException e) {
				throw new FileNotFoundException("Incorrect 'quality' query parameter");
			}

			PhotoLibraryService.PictureData thumbnailData = service.getThumbnail(getContext(), photoId, width, height, quality);

			if (thumbnailData == null) {
				throw new FileNotFoundException("Could not create thumbnail");
			}

			InputStream is = new ByteArrayInputStream(thumbnailData.bytes);

			return new CordovaResourceApi.OpenForReadResult(uri, is, thumbnailData.mimeType, is.available(), null);

		} else { // isPhoto == true

			PhotoLibraryService.PictureAsStream pictureAsStream = service.getPhotoAsStream(getContext(), photoId);
			InputStream is = pictureAsStream.getStream();

			return new CordovaResourceApi.OpenForReadResult(uri, is, pictureAsStream.getMimeType(), is.available(), null);

		}

	}

	@Override
	public void onRequestPermissionResult(int requestCode, String[] permissions, int[] grantResults) throws JSONException {
		for (int r : grantResults) {
			if (r == PackageManager.PERMISSION_DENIED) {
				this.callbackContext.error(PhotoLibraryService.PERMISSION_ERROR);
				return;
			}
		}

		this.callbackContext.success();
	}

	@Override
	public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
		for (int r : grantResults) {
			if (r == PackageManager.PERMISSION_DENIED) {
				this.callbackContext.error(PhotoLibraryService.PERMISSION_ERROR);
				return;
			}
		}

		this.callbackContext.success();
	}

	private static final int REQUEST_AUTHORIZATION_REQ_CODE = 0;

	private PhotoLibraryService service;

	private Context getContext() {
		return this.cordova.getContext().getApplicationContext();
	}

	private PluginResult createMultipartPluginResult(PluginResult.Status status, PhotoLibraryService.PictureData pictureData) throws JSONException {

		// As cordova-android 6.x uses EVAL_BRIDGE, and it breaks support for multipart result, we will encode result by ourselves.
		// see encodeAsJsMessage method of https://github.com/apache/cordova-android/blob/master/framework/src/org/apache/cordova/NativeToJsMessageQueue.java

		JSONObject resultJSON = new JSONObject();
		resultJSON.put("data", Base64.encodeToString(pictureData.bytes, Base64.NO_WRAP));
		resultJSON.put("mimeType", pictureData.mimeType);

		return new PluginResult(status, resultJSON);
	}

	private void requestAuthorization(boolean read, boolean write) {

		List<String> permissions = new ArrayList<>();

		if (read) {
			permissions.addAll(imageReadPermissions);
			permissions.addAll(videoReadPermissions);
		}

		if (write) {
			permissions.addAll(imageWritePermissions);
			permissions.addAll(videoWritePermissions);
		}

		cordova.requestPermissions(this, REQUEST_AUTHORIZATION_REQ_CODE, permissions.toArray(new String[0]));
	}

	private static JSONArray createGetAlbumsResult(ArrayList<JSONObject> albums) {
		return new JSONArray(albums);
	}

	private static JSONObject createGetLibraryResult(ArrayList<JSONObject> library, int chunkNum, boolean isLastChunk) throws JSONException {
		JSONObject result = new JSONObject();
		result.put("chunkNum", chunkNum);
		result.put("isLastChunk", isLastChunk);
		result.put("library", new JSONArray(library));
		return result;
	}

	private boolean isMissingPermissions(List<String> permissions) {
		List<String> missingPermissions = new ArrayList<>();
		for (String permission : permissions) {
			if (!PermissionHelper.hasPermission(this, permission)) {
				missingPermissions.add(permission);
			}
		}

		return !missingPermissions.isEmpty();
	}

}
