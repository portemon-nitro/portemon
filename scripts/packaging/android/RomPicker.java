package org.love2d.android;

import android.app.Activity;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.provider.OpenableColumns;

import androidx.annotation.Keep;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.lang.ref.WeakReference;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;


/** One process-owned SAF selection and private stream-copy lifetime. */
@Keep
public final class RomPicker {
    private static final int REQUEST_CODE = 0x5041;
    private static final Object LOCK = new Object();
    private static final ExecutorService COPY_EXECUTOR = Executors.newSingleThreadExecutor();
    private static RomPicker instance;
    private Pending pending;

    private static final class Pending {
        final String requestId;
        final String saveDirectory;
        final Context applicationContext;
        WeakReference<GameActivity> activity;
        boolean copying;
        Result result;

        Pending(String requestId, String saveDirectory, GameActivity activity) {
            this.requestId = requestId;
            this.saveDirectory = saveDirectory;
            this.applicationContext = activity.getApplicationContext();
            this.activity = new WeakReference<>(activity);
        }
    }

    private static final class Result {
        final String kind;
        final String relativePath;
        final String displayName;
        final String message;

        Result(String kind, String relativePath, String displayName, String message) {
            this.kind = kind;
            this.relativePath = relativePath;
            this.displayName = displayName;
            this.message = message;
        }
    }

    private RomPicker() {}

    private static RomPicker get() {
        synchronized (LOCK) {
            if (instance == null) {
                instance = new RomPicker();
            }
            return instance;
        }
    }

    @Keep
    public static String[] open(GameActivity activity, String saveDirectory) {
        RomPicker picker = get();
        synchronized (LOCK) {
            if (picker.pending != null) {
                return new String[] { null, "the previous picker operation is still finishing" };
            }
            String requestId = UUID.randomUUID().toString();
            picker.pending = new Pending(requestId, saveDirectory, activity);
            activity.runOnUiThread(() -> picker.launch(picker.pending));
            return new String[] { requestId };
        }
    }

    private void launch(Pending request) {
        GameActivity activity = request.activity.get();
        if (activity == null || activity.isFinishing()) {
            fail(request, "the game selection screen is no longer available");
            return;
        }
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("*/*");
        intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, false);
        try {
            activity.startActivityForResult(intent, REQUEST_CODE);
        } catch (Exception error) {
            fail(request, friendly(error));
        }
    }

    @Keep
    public static void attach(GameActivity activity) {
        RomPicker picker = get();
        synchronized (LOCK) {
            if (picker.pending != null) {
                picker.pending.activity = new WeakReference<>(activity);
            }
        }
    }

    @Keep
    public static void saveState(Bundle state) {
        RomPicker picker = get();
        synchronized (LOCK) {
            if (picker.pending != null) {
                state.putString("portemon_rom_picker_request", picker.pending.requestId);
            }
        }
    }

    @Keep
    public static void restore(GameActivity activity, Bundle state) {
        if (state == null || !state.containsKey("portemon_rom_picker_request")) {
            return;
        }
        RomPicker picker = get();
        synchronized (LOCK) {
            if (picker.pending != null
                    && picker.pending.requestId.equals(state.getString("portemon_rom_picker_request"))) {
                picker.pending.activity = new WeakReference<>(activity);
            }
        }
    }

    @Keep
    public static void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode != REQUEST_CODE) {
            return;
        }
        RomPicker picker = get();
        final Pending request;
        final Uri uri;
        synchronized (LOCK) {
            request = picker.pending;
            if (request == null || request.copying || request.result != null) {
                return;
            }
            if (resultCode == Activity.RESULT_CANCELED) {
                request.result = new Result("cancel", null, null, null);
                return;
            }
            uri = data == null ? null : data.getData();
            if (resultCode != Activity.RESULT_OK || uri == null) {
                request.result = new Result("error", null, null, "no document was selected");
                return;
            }
            request.copying = true;
        }
        COPY_EXECUTOR.execute(() -> picker.copy(request, uri));
    }

    private void copy(Pending request, Uri uri) {
        File directory = new File(request.saveDirectory, "imports");
        File partial = new File(directory, request.requestId + ".part");
        File output = null;
        try {
            if (!directory.isDirectory() && !directory.mkdirs()) {
                throw new IOException("could not create private import storage");
            }
            ContentResolver resolver = request.applicationContext.getContentResolver();
            String displayName = displayName(resolver, uri);
            String lowerName = displayName.toLowerCase(Locale.ROOT);
            String extension;
            if (lowerName.endsWith(".nds")) {
                extension = "nds";
            } else if (lowerName.endsWith(".zip")) {
                extension = "zip";
            } else {
                throw new IOException("choose a supported .nds or .zip file");
            }
            output = new File(directory, request.requestId + "." + extension);
            try (InputStream input = resolver.openInputStream(uri);
                    FileOutputStream stream = new FileOutputStream(partial)) {
                if (input == null) {
                    throw new IOException("the document provider could not be opened");
                }
                byte[] buffer = new byte[64 * 1024];
                int count;
                while ((count = input.read(buffer)) != -1) {
                    stream.write(buffer, 0, count);
                }
                stream.getFD().sync();
            }
            if (!partial.renameTo(output)) {
                throw new IOException("the completed private copy could not be published");
            }
            synchronized (LOCK) {
                if (pending == request) {
                    request.result = new Result("path", "imports/" + output.getName(), displayName, null);
                }
            }
        } catch (Exception error) {
            delete(partial);
            if (output != null) {
                delete(output);
            }
            fail(request, friendly(error));
        }
    }

    private static String displayName(ContentResolver resolver, Uri uri) throws IOException {
        Cursor cursor = resolver.query(uri, new String[] { OpenableColumns.DISPLAY_NAME }, null, null, null);
        if (cursor == null) {
            throw new IOException("the document name could not be read");
        }
        try {
            if (!cursor.moveToFirst()) {
                throw new IOException("the document name could not be read");
            }
            int column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
            if (column < 0) {
                throw new IOException("the document name could not be read");
            }
            String name = cursor.getString(column);
            if (name == null || name.isEmpty()) {
                throw new IOException("the document name could not be read");
            }
            return name;
        } finally {
            cursor.close();
        }
    }

    private void fail(Pending request, String message) {
        synchronized (LOCK) {
            if (pending == request && request.result == null) {
                request.result = new Result("error", null, null, message);
            }
        }
    }

    @Keep
    public static String[] poll() {
        RomPicker picker = get();
        synchronized (LOCK) {
            if (picker.pending == null || picker.pending.result == null) {
                return null;
            }
            Result result = picker.pending.result;
            String requestId = picker.pending.requestId;
            picker.pending = null;
            return new String[] {
                requestId,
                result.kind,
                result.relativePath,
                result.displayName,
                result.message,
            };
        }
    }

    private static void delete(File file) {
        if (file != null && file.exists()) {
            file.delete();
        }
    }

    private static String friendly(Exception error) {
        String message = error.getMessage();
        return message == null || message.isEmpty() ? "the document could not be copied" : message;
    }
}
