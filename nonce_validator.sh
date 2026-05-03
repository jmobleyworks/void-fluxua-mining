#!/bin/bash
#
# Nonce Validator - Functor-Based Validation Framework
# Ensures only valid mining nonces are submitted to pools
#

# NONCE VALIDATION TEMPLATE
# A valid nonce must satisfy ALL these constraints:
# 1. Format: Must be a valid hex string (0-9a-f)
# 2. Length: Between 16-128 characters
# 3. Source: Must come from dispatcher (job-TIMESTAMP-HASH format)
# 4. Not test: Must not contain test prefixes (test_, job-00, job-01, etc. < job-100)
# 5. Not empty: Must be non-zero length

# Validation functor - pass through as parameter
validate_nonce() {
  local nonce="$1"
  local job_id="${2:-}"
  local validator_chain="${3:-default}"

  # Chain validators: each returns 0 (valid) or 1 (invalid)

  # V1: Not empty
  if [ -z "$nonce" ]; then
    echo "INVALID_EMPTY"
    return 1
  fi

  # V2: Not a test nonce (block obvious test patterns)
  if [[ "$nonce" =~ ^test_ ]] || [[ "$nonce" =~ ^job-00 ]] || [[ "$nonce" =~ ^job-01 ]] || [[ "$nonce" =~ ^job-02 ]] || [[ "$nonce" =~ ^job-03 ]] || [[ "$nonce" =~ ^job-04 ]] || [[ "$nonce" =~ ^job-05 ]]; then
    echo "INVALID_TEST_NONCE"
    return 1
  fi

  # V3: Must be hex format (0-9a-f)
  if ! [[ "$nonce" =~ ^[0-9a-fA-F]+$ ]]; then
    echo "INVALID_HEX_FORMAT"
    return 1
  fi

  # V4: Length check (Monero nonces are typically 16 hex chars = 64 bits)
  local nonce_len=${#nonce}
  if [ "$nonce_len" -lt 16 ] || [ "$nonce_len" -gt 128 ]; then
    echo "INVALID_LENGTH:$nonce_len"
    return 1
  fi

  # V5: Job ID must be from dispatcher (not synthetic)
  if [ -n "$job_id" ]; then
    # Real job_ids from dispatcher match pattern: job-TIMESTAMP-HASH
    if ! [[ "$job_id" =~ ^job-[0-9]+-[a-f0-9]+$ ]]; then
      echo "INVALID_JOB_ID:$job_id"
      return 1
    fi
  fi

  # All validations passed
  echo "VALID"
  return 0
}

# Test validator
test_nonce_validator() {
  local test_nonce="$1"
  local test_job="$2"
  local result

  result=$(validate_nonce "$test_nonce" "$test_job")
  if [ "$result" = "VALID" ]; then
    echo "✓ Nonce is valid: $test_nonce"
    return 0
  else
    echo "✗ Nonce validation failed: $test_nonce → $result"
    return 1
  fi
}

# Export functions
export -f validate_nonce
export -f test_nonce_validator
