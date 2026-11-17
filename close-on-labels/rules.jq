# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026-Present The Zarf Authors
#
# Validates and normalizes close-on-labels rules.
#
# Input:  {"inline": <rule object or null>, "file": <parsed rules file or null>, "path": <rules-file path or "">,
#          "defaults": {"target", "reason", "comment", "lock"}}
# Output: {"errors": [string], "warnings": [string], "rules": [normalized rule]}
#
# A normalized rule is {"name", "kind": "close"|"keep", "or", "and", "not", "target", "reason", "comment", "lock"}.
# `and`, `or` and `not` are jq keywords, so those keys are always read as .["or"], never .or.

def trim_ws: gsub("^\\s+|\\s+$"; "");

def allowed_keys: ["name", "or", "and", "not", "target", "reason", "comment", "lock"];

# A list of labels, given as a YAML list or as a comma or newline separated string. null when malformed.
def label_list:
  (if type == "array" then . elif type == "string" then [splits("[,\n]")] else [.] end)
  | if all(.[]; type == "string" or type == "number")
    then map(tostring | trim_ws) | map(select(length > 0))
    else null
    end;

# The lowercased value when it is a string in $allowed, otherwise null.
def one_of($allowed):
  if type == "string" then ascii_downcase as $v | if $allowed | index([$v]) then $v else null end else null end;

# check($at; $default_name; $defaults): validates one rule. Returns {"errors": [...], "rule": {...}}.
def check($at; $default_name; $defaults):
  . as $r
  | if ($r | type) != "object" then
      {errors: ["\($at) must be a mapping with `or`, `and` or `not`."], rule: null}
    else
      ($r.name
        | if . == null then $default_name
          elif type == "string" or type == "number" then tostring | trim_ws
          else null end) as $name
      | "\($at) (\($name // "?"))" as $where
      | [$r | keys[] | select(. as $k | allowed_keys | index([$k]) | not)] as $unknown
      | (reduce ("or", "and", "not") as $k ({};
          if $r | has($k) then . + {($k): ($r[$k] | label_list)} else . end)) as $lists
      | (if ($lists | has("or")) or ($lists | has("and")) then "close" else "keep" end) as $kind
      | ($r.target | one_of(["issues", "prs", "all"])) as $target
      | ($r.reason | one_of(["completed", "not_planned"])) as $reason
      | {
          errors: (
            (if ($unknown | length) > 0 then
               ["\($where) has unknown key(s): \($unknown | join(", ")). Allowed: \(allowed_keys | join(", "))."]
             else [] end)
            + (if $name == null then ["\($where): `name` must be a string."]
               elif $name == "" then ["\($where): `name` is empty."]
               else [] end)
            + (if ($lists | length) == 0 then ["\($where) needs `or`, `and` or `not`."] else [] end)
            + [$lists | to_entries[]
                | if .value == null then "\($where): `\(.key)` must be a list of labels."
                  elif (.value | length) == 0 then "\($where): `\(.key)` is empty."
                  else empty end]
            + (if ($r | has("target")) and $target == null then
                 ["\($where): `target` must be one of issues, prs, all (got \($r.target | tojson))."]
               else [] end)
            + (if $kind == "keep" then
                 [("reason", "comment", "lock") as $k | select($r | has($k))
                  | "\($where): `\($k)` only applies to rules with `or` or `and`."
                    + " A rule with only `not` keeps items open."]
               else
                 (if ($r | has("reason")) and $reason == null then
                    ["\($where): `reason` must be one of completed, not_planned (got \($r.reason | tojson))."]
                  else [] end)
                 + (if ($r | has("comment")) and ($r.comment | type) != "string" then
                      ["\($where): `comment` must be a string."]
                    else [] end)
                 + (if ($r | has("lock")) and ($r.lock | type) != "boolean" then
                      ["\($where): `lock` must be true or false (got \($r.lock | tojson))."]
                    else [] end)
               end)
          ),
          rule: {
            name: $name,
            kind: $kind,
            or: ($lists["or"] // []),
            and: ($lists["and"] // []),
            not: ($lists["not"] // []),
            target: ($target // $defaults.target),
            reason: ($reason // $defaults.reason),
            comment: (if $r | has("comment") then $r.comment else $defaults.comment end),
            lock: (if $r | has("lock") then $r.lock else $defaults.lock end)
          }
        }
    end;

. as $in
| (if $in.inline == null then [] else [$in.inline | check("inputs"; "inline"; $in.defaults)] end) as $inline
| (if $in.path == "" then
     {errors: [], checked: []}
   elif ($in.file | type) != "object" or ($in.file.rules | type) != "array" or ($in.file.rules | length) == 0 then
     {errors: ["\($in.path): expected a non-empty `rules` list."], checked: []}
   else
     {errors: [], checked: [$in.file.rules | to_entries[]
       | .key as $i | .value | check("\($in.path): rules[\($i)]"; "rule-\($i + 1)"; $in.defaults)]}
   end) as $file
| ($inline + $file.checked) as $checked
| [$checked[].rule | select(. != null)] as $rules
| ([$rules[].name | select(. != null and . != "")] | group_by(.) | map(select(length > 1) | .[0])) as $dupes
| ($file.errors + ($checked | map(.errors) | add // [])) as $rule_errors
| {
    errors: (
      $rule_errors
      + [$dupes[] | "Duplicate rule name \"\(.)\". Rule names must be unique."]
      + (if ($rule_errors | length) == 0 and ([$rules[] | select(.kind == "close")] | length) == 0 then
           ["No rule can close anything. Add a rule with `or` or `and`; a rule with only `not` only keeps items open."]
         else [] end)
    ),
    warnings: (
      ([$rules | to_entries[] | select(.value.kind == "close") | .key] | max) as $last_close
      | [$rules | to_entries[]
         | select(.value.kind == "keep" and $last_close != null and .key > $last_close)
         | "Rule \"\(.value.name)\" only has `not` and comes after every rule that can close,"
           + " so it never has an effect. Move it above the rules it should protect."]
    ),
    rules: $rules
  }
