#!/bin/bash


domain=""
domain_list=""
token=""
output_file=""
verbose=false



# === Flag Parsing ===
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d)
      shift
      domain="$1"
      ;;

    -l)
      shift
      domain_list="$1"
      ;;

    -o)
      shift
      output_file="$1"
      ;;

    -v|--verbose)
      verbose=true
      ;;

    -*)
      echo "[!] Unknown flag: $1"
      exit 1
      ;;

    *)
      # Handle the first non-flag argument as the token
      if [[ -z "$token" ]]; then
        token="$1"
      fi
      ;;
  esac
  shift
done



# === Input Validation ===
if [[ -z "$token" ]] || { [[ -z "$domain" ]] && [[ -z "$domain_list" ]]; }; then
  echo "Usage:"
  echo "  Single domain: $0 -d domain.com GITHUB_TOKEN [-o output.txt] [-v]"
  echo "  Domain list:   $0 -l anylist.txt GITHUB_TOKEN [-o output.txt] [-v]"
  exit 1
fi


[[ -n "$output_file" ]] && : > "$output_file"


# Function to check the rate limit and handle retries

check_rate_limit() {
  local response="$1"
  local retry_url="$2"
  local retries=0



  while grep -q "API rate limit exceeded" <<< "$response"; do
    echo "[!] GitHub API rate limit exceeded."
    echo "[i] Waiting 2 minutes before retrying..."
    sleep 120  # Wait for 2 minutes


    echo "[*] Retrying after wait..."
    response=$(curl -s -H "Authorization: token $token" "$retry_url")
    ((retries++))


    if [[ $retries -ge 5 ]]; then
      echo "[!] Still hitting rate limit after multiple retries. Exiting."
      exit 1
    fi
  done



  echo "$response"
}



# Domain scan logic

scan_domain() {
  local domain="$1"
  $verbose && echo -e "\n[==>] Scanning $domain"


  local urls_file=$(mktemp)
  local raw_urls=$(mktemp)


  for page in {1..5}; do
    $verbose && echo "    [*] Fetching GitHub page $page..."
    url="https://api.github.com/search/code?q=%22.${domain}%22+in:file&page=$page&per_page=100"
    response=$(curl -s -H "Authorization: token $token" "$url")
    response=$(check_rate_limit "$response" "$url")



    # Check if the response is a valid JSON and contains items
    if ! echo "$response" | jq -e '.items' >/dev/null; then
      echo "[!] Warning: Invalid or empty response on page $page. Skipping..."
      continue
    fi


    echo "$response" | jq -r '.items[].html_url' >> "$urls_file"
  done



  num_urls=$(wc -l < "$urls_file")
  $verbose && echo "    [+] Found $num_urls GitHub URLs"

  sed 's/github.com/raw.githubusercontent.com/;s/blob\///' "$urls_file" > "$raw_urls"

  $verbose && echo "    [*] Fetching raw content & extracting subdomains..."
  found_subs=$(cat "$raw_urls" | xargs -n 1 -P 10 curl -s 2>/dev/null | \
    grep -Eo "[a-zA-Z0-9._-]+\.$domain" | sort -u)


  count=$(echo "$found_subs" | wc -l)
  [[ -n "$output_file" ]] && echo "$found_subs" >> "$output_file" || echo "$found_subs"

  echo "[+] $domain => Found $count subdomains"
  $verbose && echo "[---] Done with $domain"


  rm "$urls_file" "$raw_urls"
}



# === Execution ===
if [[ -n "$domain_list" ]]; then
  if [[ ! -f "$domain_list" ]]; then
    echo "[!] Error: File '$domain_list' not found."
    exit 1
  fi


  while IFS= read -r domain || [[ -n "$domain" ]]; do
    [[ -n "$domain" ]] && scan_domain "$domain"
  done < "$domain_list"



elif [[ -n "$domain" ]]; then
  scan_domain "$domain"
fi


[[ -n "$output_file" ]] && echo "[*] Final results saved to: $output_file"

