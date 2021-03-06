/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */


use cssparser::ast::{SyntaxError, SourceLocation};


pub struct ErrorLoggerIterator<I>(pub I);

impl<T, I: Iterator<Result<T, SyntaxError>>> Iterator<T> for ErrorLoggerIterator<I> {
    fn next(&mut self) -> Option<T> {
        let ErrorLoggerIterator(ref mut this) = *self;
        loop {
            match this.next() {
                Some(Ok(v)) => return Some(v),
                Some(Err(error)) => log_css_error(error.location, format!("{:?}", error.reason)),
                None => return None,
            }
        }
   }
}


/// Defaults to a no-op.
/// Set a `RUST_LOG=style::errors` environment variable
/// to log CSS parse errors to stderr.
pub fn log_css_error(location: SourceLocation, message: &str) {
    // Check this first as it’s cheaper than local_data.
    if log_enabled!(::log::INFO) {
        if silence_errors.get().is_none() {
            // TODO eventually this will got into a "web console" or something.
            info!("{:u}:{:u} {:s}", location.line, location.column, message)
        }
    }
}


local_data_key!(silence_errors: ())

pub fn with_errors_silenced<T>(f: || -> T) -> T {
    silence_errors.replace(Some(()));
    let result = f();
    silence_errors.replace(None);
    result
}
