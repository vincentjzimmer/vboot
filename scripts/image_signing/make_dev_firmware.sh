#!/bin/sh
#
# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# This script can change key (usually developer keys) in a firmware binary
# image or system live firmware (EEPROM), and assign proper HWID, FLAGS as well.

SCRIPT_BASE="$(dirname "$0")"
. "$SCRIPT_BASE/common_minimal.sh"
load_shflags || exit 1

# Constants used by DEFINE_*
VBOOT_BASE='/usr/share/vboot'
DEFAULT_KEYS_FOLDER="$VBOOT_BASE/devkeys"
DEFAULT_BACKUP_FOLDER='/mnt/stateful_partition/backups'

# DEFINE_string name default_value description flag
DEFINE_string from "" "Path of input file (empty for system live firmware)" "f"
DEFINE_string to "" "Path of output file (empty for system live firmware)" "t"
DEFINE_string keys "$DEFAULT_KEYS_FOLDER" "Path to folder of dev keys" "k"
DEFINE_string preamble_flags "" "Override preamble flags value. Known values:
                        0: None. (Using RW to boot in normal. aka, two-stop)
                        1: VB_FIRMWARE_PREAMBLE_USE_RO_NORMAL (one-stop)" "p"
DEFINE_boolean mod_hwid \
  $FLAGS_TRUE "Modify HWID to indicate this is a modified firmware" ""
DEFINE_boolean mod_gbb_flags \
  $FLAGS_TRUE "Modify GBB flags to enable developer friendly features" ""
DEFINE_boolean force_backup \
  $FLAGS_TRUE "Create backup even if source is not live" ""
DEFINE_string backup_dir \
  "$DEFAULT_BACKUP_FOLDER" "Path of directory to store firmware backups" ""

# Parse command line
FLAGS "$@" || exit 1
eval set -- "$FLAGS_ARGV"

# Globals
# ----------------------------------------------------------------------------
set -e

FLASHROM="flashrom -p host"

# the image we are (temporary) working with
IMAGE="$(make_temp_file)"
IMAGE="$(readlink -f "$IMAGE")"

# a log file to keep the output results of executed command
EXEC_LOG="$(make_temp_file)"

# Functions
# ----------------------------------------------------------------------------

# Disables write protection status registers
disable_write_protection() {
  # No need to change WP status in file mode
  if [ -n "$FLAGS_to" ]; then
    return $FLAGS_TRUE
  fi

  # --wp-disable command may return success even if WP is still enabled,
  # so we should use --wp-status to verify the results.
  echo "Disabling system software write protection status..."
  (${FLASHROM} --wp-disable && ${FLASHROM} --wp-status) 2>&1 |
    tee "$EXEC_LOG" |
    grep -q '^WP: .* is disabled\.$'
}

# Reads $IMAGE from $FLAGS_from
read_image() {
  if [ -z "$FLAGS_from" ]; then
    echo "Reading system live firmware..."
    if is_debug_mode; then
      ${FLASHROM} -V -r "$IMAGE"
    else
      ${FLASHROM} -r "$IMAGE" >"$EXEC_LOG" 2>&1
    fi
  else
    debug_msg "reading from file: $FLAGS_from"
    cp -f "$FLAGS_from" "$IMAGE"
  fi
}

# Writes $IMAGE to $FLAGS_to
write_image() {
  if [ -z "$FLAGS_to" ]; then
    echo "Writing system live firmware..."
    # TODO(hungte) we can enable partial write to make this faster
    if is_debug_mode; then
      ${FLASHROM} -w "$IMAGE" -V
    else
      ${FLASHROM} -w "$IMAGE" >"$EXEC_LOG" 2>&1
    fi
  else
    debug_msg "writing to file: $FLAGS_to"
    cp -f "$IMAGE" "$FLAGS_to"
    chmod a+r "$FLAGS_to"
  fi
}

# Converts HWID from $1 to proper format with "DEV" extension
echo_dev_hwid() {
  local hwid="$1"
  local hwid_no_dev="${hwid% DEV}"

  # NOTE: Some DEV firmware image files may put GUID in HWID.
  # These are not officially supported and they will see "{GUID} DEV".

  if [ "$hwid" != "$hwid_no_dev" ]; then
    hwid="$hwid_no_dev"
  fi
  local hwid_dev="$hwid DEV"
  debug_msg "echo_dev_hwid: [$1] -> [$hwid_dev]"
  echo "$hwid_dev"
}

# Main
# ----------------------------------------------------------------------------
main() {
  # Check parameters
  local root_pubkey="$FLAGS_keys/root_key.vbpubk"
  local recovery_pubkey="$FLAGS_keys/recovery_key.vbpubk"
  local firmware_keyblock="$FLAGS_keys/firmware.keyblock"
  local firmware_prvkey="$FLAGS_keys/firmware_data_key.vbprivk"
  local dev_firmware_keyblock="$FLAGS_keys/dev_firmware.keyblock"
  local dev_firmware_prvkey="$FLAGS_keys/dev_firmware_data_key.vbprivk"
  local kernel_sub_pubkey="$FLAGS_keys/kernel_subkey.vbpubk"
  local is_from_live=0
  local backup_image=

  debug_msg "Prerequisite check"
  ensure_files_exist \
    "$root_pubkey" \
    "$recovery_pubkey" \
    "$firmware_keyblock" \
    "$firmware_prvkey" \
    "$kernel_sub_pubkey" ||
    exit 1

  if [ -z "$FLAGS_from" ]; then
    is_from_live=1
  else
    ensure_files_exist "$FLAGS_from" || exit 1
  fi

  debug_msg "Checking software write protection status"
  disable_write_protection ||
    if is_debug_mode; then
      err_die "Failed to disable WP. Diagnose Message: $(cat "$EXEC_LOG")"
    else
      err_die "Write protection is still enabled. " \
              "Please verify that hardware write protection is disabled."
    fi

  debug_msg "Pulling image to $IMAGE"
  (read_image && [ -s "$IMAGE" ]) ||
    err_die "Failed to read image. Error message: $(cat "$EXEC_LOG")"

  debug_msg "Prepare to backup the file"
  if [ -n "$is_from_live" -o $FLAGS_force_backup = $FLAGS_TRUE ]; then
    backup_image="$(make_temp_file)"
    debug_msg "Creating backup file to $backup_image..."
    cp -f "$IMAGE" "$backup_image"
  fi

  debug_msg "Detecting developer firmware keyblock"
  local expanded_firmware_dir="$(make_temp_dir)"
  local use_devfw_keyblock="$FLAGS_FALSE"
  (cd "$expanded_firmware_dir"; dump_fmap -x "$IMAGE" >/dev/null 2>&1) ||
    err_die "Failed to extract firmware image."
  if [ -f "$expanded_firmware_dir/VBLOCK_A" ]; then
    local has_dev=$FLAGS_TRUE has_norm=$FLAGS_TRUE
    # In output of vbutil_keyblock, "!DEV" means "bootable on normal mode" and
    # "DEV" means "bootable on developer mode". Here we try to match the pattern
    # in output of vbutil_block, and disable the flags (has_dev, has_norm) if
    # the pattern was not found.
    vbutil_keyblock --unpack "$expanded_firmware_dir/VBLOCK_A" |
      grep -qw '!DEV' || has_norm=$FLAGS_FALSE
    vbutil_keyblock --unpack "$expanded_firmware_dir/VBLOCK_A" |
      grep -qw '[^!]DEV' || has_dev=$FLAGS_FALSE
    if [ "$has_norm" = "$FLAGS_FALSE" -a "$has_dev" = "$FLAGS_TRUE" ]; then
      use_devfw_keyblock=$FLAGS_TRUE
    fi
  fi

  if [ "$use_devfw_keyblock" = "$FLAGS_TRUE" ]; then
    echo "Using keyblocks (developer, normal)..."
  else
    echo "Using keyblocks (normal, normal)..."
    dev_firmware_prvkey="$firmware_prvkey"
    dev_firmware_keyblock="$firmware_keyblock"
  fi

  debug_msg "Extract firmware version and data key version"
  gbb_utility -g --rootkey="$expanded_firmware_dir/rootkey" "$IMAGE" >/dev/null 2>&1

  local data_key_version firmware_version
  # When we are going to flash directly from or to system, the versions stored
  # in TPM can be found by crossystem; otherwise we'll need to guess from source
  # firmware (FLAGS_from).
  if [ -z "$FLAGS_to" -o -z "$FLAGS_from" ]; then
    debug_msg "Reading TPM version from crossystem tpm_fwver."
    data_key_version="$(( $(crossystem tpm_fwver) >> 16 ))"
    firmware_version="$(( $(crossystem tpm_fwver) & 0xFFFF ))"
  else
    # TODO(hungte) On Vboot2, A/B slot may contain different firmware so we may
    # need to check both and decide from largest number.
    debug_msg "Guessing TPM version from original firmware."
    local fw_info="$(vbutil_firmware \
                     --verify "$expanded_firmware_dir/VBLOCK_A" \
                     --signpubkey "$expanded_firmware_dir/rootkey" \
                     --fv "$expanded_firmware_dir/FW_MAIN_A")" 2>/dev/null ||
        err_die "Failed to verify firmware slot A."
    data_key_version="$(
      echo "$fw_info" | sed -n '/^ *Data key version:/s/.*:[ \t]*//p')"
    firmware_version="$(
      echo "$fw_info" | sed -n '/^ *Firmware version:/s/.*:[ \t]*//p')"
  fi

  local new_data_key_version="$(
    vbutil_keyblock --unpack "$firmware_keyblock" |
    sed -n '/^ *Data key version:/s/.*:[ \t]*//p')"

  # TODO(hungte) Change key block by data_key_version.
  if [ "$data_key_version" -gt "$new_data_key_version" ]; then
    echo "$(tput bold)$(tput setaf 1)
    Warning: firmware data key version <$new_data_key_version> in your new keys
    [$FLAGS_keys] is smaller than original firmware <$data_key_version> and
    will boot into only recovery mode due to TPM anti-rollback detection.

    After reboot with dev recovery key, you will need to reset TPM by booting a
    test or dev image in recovery mode (NOT Ctrl-U), switch to VT2 and run
    command <chromoes-tpm-recovery>; or use a factory install shim image
    (build_image factory_install).
    $(tput sgr 0)" >&2
  fi

  echo "Signing with Data Key Version: $data_key_version, " \
       "Firmware Version: $firmware_version"

  echo "Preparing new firmware image..."

  debug_msg "Resign the firmware code (A/B) with new keys"
  # Note resign_firmwarefd.sh needs the original rootkey to determine firmware
  # body size, so we must resign image before changing GBB rootkey.

  local unsigned_image="$(make_temp_file)"
  local optional_opts=""
  if [ -n "$FLAGS_preamble_flags" ]; then
    debug_msg "Setting FLAGS=$FLAGS_preamble_flags"
    optional_opts="$FLAGS_preamble_flags"
  fi
  cp -f "$IMAGE" "$unsigned_image"
  "$SCRIPT_BASE/resign_firmwarefd.sh" \
    "$unsigned_image" \
    "$IMAGE" \
    "$firmware_prvkey" \
    "$firmware_keyblock" \
    "$dev_firmware_prvkey" \
    "$dev_firmware_keyblock" \
    "$kernel_sub_pubkey" \
    "$firmware_version" \
    $optional_opts >"$EXEC_LOG" 2>&1 ||
    err_die "Failed to re-sign firmware. (message: $(cat "$EXEC_LOG"))"
    if is_debug_mode; then
      cat "$EXEC_LOG"
    fi

  debug_msg "Extract current HWID"
  local old_hwid
  old_hwid="$(gbb_utility --get --hwid "$IMAGE" 2>"$EXEC_LOG" |
              sed -rne 's/^hardware_id: (.*)$/\1/p')"

  debug_msg "Decide new HWID"
  [ -z "$old_hwid" ] &&
    err_die "Cannot find current HWID. (message: $(cat "$EXEC_LOG"))"
  local new_hwid="$old_hwid"
  if [ "$FLAGS_mod_hwid" = "$FLAGS_TRUE" ]; then
    new_hwid="$(echo_dev_hwid "$old_hwid")"
  fi

  local old_gbb_flags
  old_gbb_flags="$(gbb_utility --get --flags "$IMAGE" 2>"$EXEC_LOG" |
                   sed -rne 's/^flags: (.*)$/\1/p')"
  debug_msg "Decide new GBB flags from: $old_gbb_flags"
  [ -z "$old_gbb_flags" ] &&
    err_die "Cannot find GBB flags. (message: $(cat "$EXEC_LOG"))"
  # 0x30: GBB_FLAG_FORCE_DEV_BOOT_USB | GBB_FLAG_DISABLE_FW_ROLLBACK_CHECK
  local new_gbb_flags="$((old_gbb_flags | 0x30))"

  debug_msg "Replace GBB parts (gbb_utility allows changing on-the-fly)"
  gbb_utility --set \
    --hwid="$new_hwid" \
    --rootkey="$root_pubkey" \
    --recoverykey="$recovery_pubkey" \
    "$IMAGE" >"$EXEC_LOG" 2>&1 ||
    err_die "Failed to change GBB Data. (message: $(cat "$EXEC_LOG"))"

  # Old firmware does not support GBB flags, so let's make it an exception.
  if [ "$FLAGS_mod_gbb_flags" = "$FLAGS_TRUE" ]; then
    debug_msg "Changing GBB flags from $old_gbb_flags to $new_gbb_flags"
    gbb_utility --set \
      --flags="$new_gbb_flags" \
      "$IMAGE" >"$EXEC_LOG" 2>&1 ||
      echo "Warning: GBB flags ($old_gbb_flags -> $new_gbb_flags) can't be set."
  fi

  # TODO(hungte) compare if the image really needs to be changed.

  debug_msg "Check if we need to make backup file(s)"
  if [ -n "$backup_image" ]; then
    local backup_hwid_name="$(echo "$old_hwid" | sed 's/ /_/g')"
    local backup_date_time="$(date +'%Y%m%d_%H%M%S')"
    local backup_file_name="firmware_${backup_hwid_name}_${backup_date_time}.fd"
    local backup_file_path="$FLAGS_backup_dir/$backup_file_name"
    if mkdir -p "$FLAGS_backup_dir" &&
       cp -f "$backup_image" "$backup_file_path"; then
      true
    elif cp -f "$backup_image" "/tmp/$backup_file_name"; then
      backup_file_path="/tmp/$backup_file_name"
    else
      backup_file_path=''
    fi
    if [ -n "$backup_file_path" -a -s "$backup_file_path" ]; then
      # TODO(hungte) maybe we can wrap the flashrom by 'make_dev_firmware.sh -r'
      # so that the only command to remember would be make_dev_firmware.sh.
      echo "
      Backup of current firmware image is stored in:
        $backup_file_path
      Please copy the backup file to a safe place ASAP.

      To stop using devkeys and restore original firmware, execute command:
        ${FLASHROM} -w [PATH_TO_BACKUP_IMAGE]
      Ex: ${FLASHROM} -w $backup_file_path
      "
    else
      echo "WARNING: Cannot create file in $FLAGS_backup_dir... Ignore backups."
    fi
  fi

  # TODO(hungte) use vbutil_firmware to check if the new firmware is valid.
  # Or, do verification in resign_firmwarefd.sh and trust it.

  debug_msg "Write the image"
  write_image ||
    err_die "Failed to write image. Error message: $(cat "$EXEC_LOG")"

  debug_msg "Complete."
  if [ -z "$FLAGS_to" ]; then
    echo "Successfully changed firmware to Developer Keys. New HWID: $new_hwid"
  else
    echo "Firmware '$FLAGS_to' now uses Developer Keys. New HWID: $new_hwid"
  fi
}

main
