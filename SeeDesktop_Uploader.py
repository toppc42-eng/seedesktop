import tkinter as tk
from tkinter import filedialog, messagebox
import json
import os
from datetime import datetime
try:
    from google.cloud import storage
except ImportError:  # pragma: no cover - runtime guidance for local setup
    storage = None

# ==========================================
# --- Google Cloud Storage Configuration ---
# ==========================================
GCS_BUCKET_NAME = "my-saas-uploads-2025"
REMOTE_DIR = "seedesktop/updates"
DOWNLOAD_BASE_URL = f"https://storage.googleapis.com/{GCS_BUCKET_NAME}/{REMOTE_DIR}"
UPDATE_PACKAGE_NAME = "SeeDesktopinst.zip"
GCS_CREDENTIALS_FILE = os.getenv("SEEDESKTOP_GCS_CREDENTIALS", "credentials.json")
# ==========================================

class UploaderApp:
    def __init__(self, root):
        self.root = root
        self.root.title("SeeDesktop - OTA Uploader")
        self.root.geometry("480x420")
        self.root.configure(padx=20, pady=20)
        self.selected_file_path = None

        # Title
        tk.Label(root, text="🚀 Publish New Version", font=("Arial", 16, "bold"), fg="#0ea5e9").pack(pady=(0, 20))

        # Version Number
        tk.Label(root, text="Version Number (e.g. 1.0.5):", font=("Arial", 10, "bold")).pack(anchor="w")
        self.version_entry = tk.Entry(root, font=("Arial", 12), width=20)
        self.version_entry.pack(fill="x", pady=(0, 15))

        # Release Notes
        tk.Label(root, text="Release Notes (What's new?):", font=("Arial", 10, "bold")).pack(anchor="w")
        self.notes_text = tk.Text(root, height=4, font=("Arial", 10))
        self.notes_text.pack(fill="x", pady=(0, 15))

        # File Selection
        tk.Label(root, text="Software File (.zip):", font=("Arial", 10, "bold")).pack(anchor="w")
        file_frame = tk.Frame(root)
        file_frame.pack(fill="x", pady=(0, 15))
        
        self.btn_select = tk.Button(file_frame, text="Browse...", command=self.select_file)
        self.btn_select.pack(side="left")
        
        self.lbl_file = tk.Label(file_frame, text="No file selected", fg="gray", wraplength=250)
        self.lbl_file.pack(side="left", padx=10)

        # Upload Button
        self.btn_upload = tk.Button(root, text="⬆️ Upload & Publish", font=("Arial", 12, "bold"), bg="#10b981", fg="white", command=self.upload_file)
        self.btn_upload.pack(fill="x", pady=10)
        
        # Status Label
        self.lbl_status = tk.Label(root, text="Ready", font=("Arial", 10, "bold"), fg="gray")
        self.lbl_status.pack()

    def select_file(self):
        file_path = filedialog.askopenfilename(
            title="Select SeeDesktop Update File",
            filetypes=[("Zip Files", "*.zip"), ("All Files", "*.*")]
        )
        if file_path:
            self.selected_file_path = file_path
            self.lbl_file.config(text=os.path.basename(file_path), fg="black")

    def upload_file(self):
        if storage is None:
            messagebox.showerror(
                "Missing Dependency",
                "google-cloud-storage is not installed.\nRun: pip install google-cloud-storage",
            )
            return
        if not self.selected_file_path:
            messagebox.showwarning("Missing File", "Please select a software (.zip) file to upload.")
            return
        if not self.selected_file_path.lower().endswith(".zip"):
            messagebox.showwarning("Invalid File", "Please select a .zip update package.")
            return
            
        version = self.version_entry.get().strip()
        if not version:
            messagebox.showwarning("Missing Version", "Please enter a version number.")
            return

        notes = self.notes_text.get("1.0", tk.END).strip()

        self.lbl_status.config(text="🔄 Connecting to Google Cloud Storage...", fg="blue")
        self.btn_upload.config(state="disabled")
        self.root.update()

        try:
            # 1) Connect
            client = storage.Client.from_service_account_json(GCS_CREDENTIALS_FILE)
            bucket = client.bucket(GCS_BUCKET_NAME)

            # 2) Upload software file
            remote_filename = UPDATE_PACKAGE_NAME
            self.lbl_status.config(text=f"⬆️ Uploading {remote_filename}...", fg="blue")
            self.root.update()

            blob = bucket.blob(f"{REMOTE_DIR}/{remote_filename}")
            blob.upload_from_filename(self.selected_file_path, content_type="application/zip")

            # 3) Generate and upload version.json
            self.lbl_status.config(text="📝 Updating version.json...", fg="blue")
            self.root.update()

            json_data = {
                'latest_version': version,
                'release_notes': notes,
                'download_url': f"{DOWNLOAD_BASE_URL}/{remote_filename}",
                'release_date': datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            }

            version_blob = bucket.blob(f"{REMOTE_DIR}/version.json")
            # Keep manifest uncached so OTA checks update immediately.
            version_blob.cache_control = "no-store, max-age=0"
            version_blob.upload_from_string(
                json.dumps(json_data, indent=4), content_type="application/json"
            )

            self.lbl_status.config(text="✅ Published Successfully!", fg="green")
            messagebox.showinfo("Success", f"Version {version} has been published!\nThe system is now live for all users.")

        except Exception as e:
            self.lbl_status.config(text="❌ Upload Error", fg="red")
            messagebox.showerror("Error", f"An error occurred:\n{str(e)}")
        finally:
            self.btn_upload.config(state="normal")

if __name__ == "__main__":
    root = tk.Tk()
    app = UploaderApp(root)
    root.mainloop()
