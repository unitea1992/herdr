//! Build identity helpers.

pub const BASE_VERSION: &str = env!("CARGO_PKG_VERSION");

pub fn channel() -> &'static str {
    non_empty(option_env!("HERDR_BUILD_CHANNEL")).unwrap_or("stable")
}

pub fn build_id() -> Option<&'static str> {
    non_empty(option_env!("HERDR_BUILD_ID"))
}

/// The `--version` string. Stable builds report the plain Cargo version and
/// preview builds keep the upstream `-preview.<id>` form. Any other channel
/// (e.g. a personal fork build) is reported as semver build metadata
/// `+<channel>.<id>`, so `HERDR_BUILD_CHANNEL=tabbycwd HERDR_BUILD_ID=<sha>`
/// yields `0.8.0+tabbycwd.<sha>`.
pub fn version() -> String {
    match channel() {
        "stable" => BASE_VERSION.to_string(),
        "preview" => match build_id() {
            Some(build_id) => format!("{BASE_VERSION}-preview.{build_id}"),
            None => format!("{BASE_VERSION}-preview"),
        },
        channel => match build_id() {
            Some(build_id) => format!("{BASE_VERSION}+{channel}.{build_id}"),
            None => format!("{BASE_VERSION}+{channel}"),
        },
    }
}

pub fn is_preview() -> bool {
    channel() == "preview"
}

fn non_empty(value: Option<&'static str>) -> Option<&'static str> {
    value.and_then(|value| {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed)
        }
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn stable_version_defaults_to_cargo_version() {
        assert!(!super::version().is_empty());
    }
}
