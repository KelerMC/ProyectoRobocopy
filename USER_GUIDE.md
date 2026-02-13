# 📁 User Guide - Automated NAS Transfer

**Version 1.0** | Tool for copying files to NAS safely and efficiently

---

## 🚀 Quick Start

### What does this program do?
Copies complete folders from your computer to the NAS (network storage) automatically.

### Requirements
- ✅ Windows 11
- ✅ Network connection to NAS
- ✅ NAS credentials (username and password)

---

## 📖 How to Use the Program

### **Step 1: Preparation**

1. **Verify NAS access** (IMPORTANT - REQUIRED):
   - Open **File Explorer**
   - In the address bar type: `\\192.168.1.254`
   - Press Enter
   - **If credentials are requested, enter them and check "Remember my credentials"**
   - Verify you can see the NAS folders
   - ✅ **This step prevents the script from requesting credentials again**

2. **Configure permissions** (first time only):
   - Open PowerShell
   - Execute: `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`
   - Confirm with `Y`

3. **Locate the script**:
   - Save `NAS-Transfer-v1.0.ps1` in an easy-to-find folder
   - Example: `C:\Scripts\`

---

### **Step 2: Run the Program**

1. **Right-click** on the file `NAS-Transfer-v1.0.ps1`
2. Select **"Run with PowerShell"**

![Initial screen]
```
================================
 AUTOMATED NAS TRANSFER
 Version 1.0
================================

Select destination folder on NAS:

  1. Historical
  2. EDI
  3. ATO
  4. Testing
  5. Other

Enter option (1-5):
```

---

### **Step 3: Select NAS Destination**

**Recommended option**: Choose `1`, `2`, `3`, or `4` for predefined folders

**Advanced option**: Choose `5` to enter a custom path
- Format: `\\192.168.1.254\FolderName`
- Example: `\\192.168.1.254\Projects`

---

### **Step 4: Select Source Folder**

```
Enter SOURCE path (complete folder): 
```

**Valid examples:**
- `C:\Documents\Project2024`
- `D:\Backups\Important`
- `\\OtherPC\Shared\Data`

**💡 Tip**: You can copy the path from Windows Explorer

---

### **Step 5: Automatic Validations**

The program will verify:

✅ **Files found**: How many files were detected
```
Analyzing source files...
Files found: 1234
```

⚠️ **Possible warnings**:
- Special characters in names (like `<>"|?*`)
- Very long paths (>240 characters)
- Files that might be open

**What to do?**
- If warning appears → You can continue (`Y`) or cancel (`N`)
- The program will attempt to copy anyway

---

### **Step 6: Confirm Destination**

```
Summary:
Source     : C:\Documents\Project2024
Destination: \\192.168.1.254\Testing\Project2024
Log        : C:\Logs\robocopy_20260212_143055_transfer1.txt

Start transfer?
Enter Y to continue or N to specify another destination:
```

- **Y** = Continue
- **N** = Change destination folder

---

### **Step 7: Existing Files** (if applicable)

If destination already has files:

```
Destination contains existing files

Transfer information:
  Total files in SOURCE: 16 files
  Total size: 67.3 MB
  Files found in DESTINATION: 50+ files

Analyze files before copying? (Y/N):
```

**💡 New behavior:**
- **ANALYZES YOUR SOURCE FILES** (not destination files)
- Shows exactly which files FROM YOUR SOURCE will be copied or skipped
- More accurate prediction for strategy #1 (Replace if newer)

**If you choose Y**, the program will analyze up to 20 files from YOUR SOURCE:

```
Analyzing SOURCE files (sample of up to 20)...
Comparing with destination files for 'Replace if newer' strategy

  ✓ \nochancar1.txt [NEWER - will be copied]
  ✗ \nochancar2.txt [same date - will be skipped]
  ✗ \nochancar3.txt [same date - will be skipped]
  ✓ \BBBB_BBBB\newFile.pdf [NEW - will be copied]
  ✓ \BBBB_BBBB\modifiedFile.xlsx [NEWER - will be copied]
  ✗ \BBBB_BBBB\unchangedFile.doc [same date - will be skipped]
  ... and 10 more file(s) not shown

========================================
PREDICTION (based on sample of 20 files):
========================================
  ✓ Will be copied (new or more recent): 13
  ✗ Will be skipped (same date or older): 3

  💡 This analysis shows files from YOUR SOURCE
     Robocopy will process all 16 files
========================================
```

**🔍 Legend:**
- **✓** (green checkmark) = WILL COPY this file
  - `[NEWER]`: Your version is more recent
  - `[NEW]`: Does not exist in destination
- **✗** (gray cross) = WILL SKIP this file
  - `[same date]`: Identical dates
  - `[older]`: Destination has newer version

**🎯 Advantages of new analysis:**
1. Shows YOUR files that will be copied
2. Identifies NEW files (that don't exist in destination)
3. More accurate prediction of what Robocopy will do
4. Easy to understand: ✓ = copy, ✗ = skip

**Then choose strategy:**
```
Select copy strategy:
(This strategy will apply to ALL files in the transfer)

  1. Replace if newer (recommended)
  2. Skip existing files
  3. Overwrite all

Select (1-3, Enter=1):
```

| Option | What it does | When to use |
|--------|--------------|-------------|
| **1** | Compares dates for each file. Only copies if source is newer | Update backups, incremental sync |
| **2** | Does not touch files that already exist at destination (regardless of date) | Preserve destination versions, don't overwrite anything |
| **3** | Replaces EVERYTHING without comparing dates | Force complete copy from scratch |

**💡 Key summary**: 
- The 20-file analysis is ONLY to help you understand how it works
- Real numbers will be shown at the end in the Robocopy summary
- Robocopy compares EACH file from your source against what exists in destination

---

### **Step 8: File Options**

```
Exclude temporary and system files?
  - Temporary files: ~$*, *.tmp, *.temp, *.bak
  - System folders: Thumbs.db, .DS_Store, desktop.ini

Exclude temporary files? (Y/N):
```

**Recommendation**: `Y` to exclude unnecessary files

---

### **Step 9: Space Verification**

```
Verifying available space...
Required space: 2.5 GB
Available space: 150 GB
Sufficient space available

Timeout configured: 7.5 minutes (adjusted by size)
```

✅ The program automatically calculates maximum wait time

---

### **Step 10: Transfer in Progress**

```
Starting transfer...

Copying files... (may take several minutes)
Activity monitor:

 [Log: 5.2 KB - Active]
```

**During copy:**
- You'll see updates every 30 seconds
- The program verifies connection automatically
- If a problem is detected, it stops to prevent errors

**⏱️ Estimated time**: Depends on size and number of files
- 100 MB → ~30 seconds
- 1 GB → ~3-5 minutes
- 10 GB → ~30-40 minutes

---

### **Step 11: Final Summary**

```
--------------------------------
 TRANSFER SUMMARY
--------------------------------

Dirs :        10         0        10         0         0         0
Files:       123       123         0         0         0         0
Bytes:  256.5 MB  256.5 MB         0         0         0         0

================================
 TRANSFER COMPLETED
================================
Status: Success - Files copied correctly
Log: C:\Logs\robocopy_20260212_143055_transfer1.txt

Perform another transfer? (Y/N):
```

**Options:**
- **Y** = Do another transfer (without closing program)
- **N** = Exit program

---

## 🔍 Understanding the Summary

| Column | Meaning |
|--------|---------|
| **Dirs** | Number of folders |
| **Files** | Number of files |
| **Bytes** | Total size copied |

**Possible statuses:**
- ✅ **Success**: Everything copied correctly
- ✅ **No changes**: Files were already up to date
- ⚠️ **Warning**: Some files don't match
- ❌ **Error**: Some files were NOT copied

---

## 📋 Logs and Records

### Log Location
```
C:\Logs\robocopy_YYYYMMDD_HHMMSS_transferN.txt
```

**Example**: `robocopy_20260212_143055_transfer1.txt`
- `20260212` = Date (February 12, 2026)
- `143055` = Time (14:30:55)
- `transfer1` = Transfer number in session

### What are logs for?
- 📝 See which files were copied
- ❌ Identify specific errors
- 📊 Detailed transfer statistics
- 🔍 Audit and tracking

---

## ⚠️ Common Problems

### ❌ "ERROR: Path does not exist"
**Cause**: The folder you entered was not found  
**Solution**: Verify the path is correctly written and exists

### ❌ "Could not connect to NAS"
**Cause**: Incorrect credentials or NAS unavailable  
**Solution**: 
1. Verify username and password
2. Confirm NAS is powered on
3. Verify network connection

### ⚠️ "Files with special characters"
**Cause**: Names with `< > : " | ? *`  
**Solution**: You can continue, but consider renaming those files

### ⚠️ "Files that may be in use"
**Cause**: Excel, Word or other programs have files open  
**Solution**: Close files before copying (recommended)

### ⏱️ "Robocopy stuck in retry loop"
**Cause**: Connection loss or permission problem  
**Solution**: The program will stop automatically after 90 seconds

---

## 💡 Tips and Best Practices

### ✅ Before copying:
1. **Close open files** in Office
2. **Verify available space** on NAS
3. **Use simple names** without special characters

### ✅ During copy:
1. **Don't disconnect** network cable
2. **Don't turn off** computer
3. **Don't suspend** device

### ✅ After copying:
1. **Review summary** to confirm success
2. **Verify files** on NAS if critical
3. **Check log** if there were warnings

---

## 🔐 Security

### Is this program safe?
✅ **Yes**, the program:
- Does not modify original files
- Only **copies** (doesn't move or delete)
- Uses native Windows tools (Robocopy)
- Credentials handled by Windows system
- Doesn't send data to internet

### What permissions does it need?
- ❌ **Doesn't need** administrator permissions
- ✅ Only needs NAS access (with your credentials)

---

## 📞 Support

### Need help?

**Check the log:**
```
C:\Logs\robocopy_[date]_[time]_transfer[N].txt
```

**Useful information to report problems:**
- Exact error message
- Source and destination path
- Log file contents
- File size and quantity

**Contact:**
- IT Area - EVT Peru Branch
- Keler Modesto

---

## 📚 Glossary

| Term | Meaning |
|------|---------|
| **NAS** | Network attached storage |
| **Robocopy** | Windows tool for copying files |
| **UNC** | Network path format (`\\server\folder`) |
| **Timeout** | Maximum wait time without activity |
| **Log** | Record file with operation details |

---

## 📄 Document Version

**Version**: 1.0  
**Date**: February 13, 2026  
**Compatible with**: NAS-Transfer-v1.0.ps1 (v1.0)  
**Status**: Pre-production

---

✨ **Thank you for using Automated NAS Transfer!** ✨
