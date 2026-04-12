#![allow(clippy::not_unsafe_ptr_arg_deref)]

use std::ffi::{c_char, CStr, CString};
use std::panic::{self, AssertUnwindSafe};
use std::ptr;
use std::sync::atomic::{AtomicU64, Ordering};

use scryer_prolog::{LeafAnswer, MachineBuilder, Term};

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

fn term_to_json(term: &Term) -> serde_json::Value {
    match term {
        Term::Integer(n) => serde_json::Value::String(n.to_string()),
        Term::Rational(r) => serde_json::Value::String(r.to_string()),
        Term::Float(f) => serde_json::json!(f),
        Term::Atom(s) => serde_json::Value::String(s.clone()),
        Term::String(s) => serde_json::Value::String(s.clone()),
        Term::List(items) => serde_json::Value::Array(items.iter().map(term_to_json).collect()),
        Term::Compound(functor, args) => serde_json::json!({
            "functor": functor,
            "args": args.iter().map(term_to_json).collect::<Vec<_>>()
        }),
        Term::Var(name) => serde_json::Value::String(format!("_{name}")),
        _ => serde_json::Value::Null,
    }
}

fn with_suppressed_panics<F, T>(f: F) -> std::thread::Result<T>
where
    F: FnOnce() -> T + std::panic::UnwindSafe,
{
    let prev = panic::take_hook();
    panic::set_hook(Box::new(|_| {}));
    let result = panic::catch_unwind(f);
    panic::set_hook(prev);
    result
}

fn ensure_dot(goal: &str) -> String {
    if goal.trim_end().ends_with('.') {
        goal.to_owned()
    } else {
        format!("{goal}.")
    }
}

fn run_command(
    handle: *mut std::ffi::c_void,
    input: *const c_char,
    build_query: impl FnOnce(&str) -> String,
    accept_false: bool,
) -> i32 {
    if handle.is_null() || input.is_null() {
        return -1;
    }
    let input_str = match unsafe { CStr::from_ptr(input).to_str() } {
        Ok(s) => s.to_owned(),
        Err(_) => return -1,
    };
    let machine = unsafe { &mut *(handle as *mut scryer_prolog::Machine) };
    let query = build_query(&input_str);
    with_suppressed_panics(AssertUnwindSafe(|| {
        if let Some(answer) = machine.run_query(&query).next() {
            match answer {
                Ok(LeafAnswer::True) | Ok(LeafAnswer::LeafAnswer { .. }) => 0,
                Ok(LeafAnswer::False) if accept_false => 0,
                Ok(LeafAnswer::False) | Ok(LeafAnswer::Exception(_)) | Err(_) => -1,
            }
        } else {
            0
        }
    }))
    .unwrap_or(-1)
}

#[no_mangle]
pub extern "C" fn prolog_init() -> *mut std::ffi::c_void {
    let machine = Box::new(MachineBuilder::default().build());
    Box::into_raw(machine) as *mut std::ffi::c_void
}

#[no_mangle]
pub extern "C" fn prolog_deinit(handle: *mut std::ffi::c_void) {
    if !handle.is_null() {
        unsafe { drop(Box::from_raw(handle as *mut scryer_prolog::Machine)) };
    }
}

#[no_mangle]
pub extern "C" fn prolog_query(handle: *mut std::ffi::c_void, goal: *const c_char) -> *mut c_char {
    if handle.is_null() || goal.is_null() {
        return ptr::null_mut();
    }
    let goal_str = match unsafe { CStr::from_ptr(goal).to_str() } {
        Ok(s) => ensure_dot(s),
        Err(_) => return ptr::null_mut(),
    };

    let machine = unsafe { &mut *(handle as *mut scryer_prolog::Machine) };

    let solutions = with_suppressed_panics(AssertUnwindSafe(|| {
        let mut solutions = Vec::new();
        for answer in machine.run_query(&goal_str) {
            match answer {
                Ok(LeafAnswer::True) => {
                    solutions.push(serde_json::Value::Object(Default::default()));
                }
                Ok(LeafAnswer::False) => break,
                Ok(LeafAnswer::LeafAnswer { bindings, .. }) => {
                    let obj: serde_json::Map<String, serde_json::Value> = bindings
                        .into_iter()
                        .map(|(k, v)| (k, term_to_json(&v)))
                        .collect();
                    solutions.push(serde_json::Value::Object(obj));
                }
                Ok(LeafAnswer::Exception(e)) => {
                    solutions.push(serde_json::json!({"error": term_to_json(&e)}));
                    break;
                }
                Err(e) => {
                    solutions.push(serde_json::json!({"error": term_to_json(&e)}));
                    break;
                }
            }
        }
        solutions
    }));

    let solutions = solutions.unwrap_or_default();
    let json = serde_json::to_string(&solutions).unwrap_or_else(|_| "[]".to_string());
    CString::new(json)
        .map(|s| s.into_raw())
        .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn prolog_assert(handle: *mut std::ffi::c_void, clause: *const c_char) -> i32 {
    run_command(
        handle,
        clause,
        |s| {
            if s.contains(":-") {
                format!("assertz(({s})).")
            } else {
                format!("assertz({s}).")
            }
        },
        false,
    )
}

#[no_mangle]
pub extern "C" fn prolog_retract(handle: *mut std::ffi::c_void, clause: *const c_char) -> i32 {
    run_command(handle, clause, |s| format!("once(retract({s}))."), false)
}

#[no_mangle]
pub extern "C" fn prolog_retractall(handle: *mut std::ffi::c_void, head: *const c_char) -> i32 {
    // retractall/1 always succeeds per ISO Prolog; accept_false: true
    run_command(handle, head, |s| format!("retractall({s})."), true)
}

#[no_mangle]
pub extern "C" fn prolog_load_file(handle: *mut std::ffi::c_void, path: *const c_char) -> i32 {
    if handle.is_null() || path.is_null() {
        return -1;
    }
    let path_str = match unsafe { CStr::from_ptr(path).to_str() } {
        Ok(s) => s.to_owned(),
        Err(_) => return -1,
    };

    if std::fs::metadata(&path_str).is_err() {
        return -1;
    }

    let machine = unsafe { &mut *(handle as *mut scryer_prolog::Machine) };
    let escaped = path_str.replace('\'', "\\'");
    let query = format!("consult('{escaped}').");

    with_suppressed_panics(AssertUnwindSafe(|| {
        if let Some(answer) = machine.run_query(&query).next() {
            match answer {
                Ok(LeafAnswer::True) | Ok(LeafAnswer::LeafAnswer { .. }) => 0,
                Ok(LeafAnswer::False) | Ok(LeafAnswer::Exception(_)) | Err(_) => -1,
            }
        } else {
            0
        }
    }))
    .unwrap_or(-1)
}

#[no_mangle]
pub extern "C" fn prolog_load_string(handle: *mut std::ffi::c_void, source: *const c_char) -> i32 {
    if handle.is_null() || source.is_null() {
        return -1;
    }
    let source_str = match unsafe { CStr::from_ptr(source).to_str() } {
        Ok(s) => s.to_owned(),
        Err(_) => return -1,
    };

    // Write to a temp file and consult via run_query so parse errors become
    // Prolog exceptions (LeafAnswer::Exception) instead of corrupting machine state.
    let tmp_path = std::env::temp_dir().join(format!(
        "zpm_load_{}_{}.pl",
        std::process::id(),
        TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    if std::fs::write(&tmp_path, &source_str).is_err() {
        return -1;
    }

    let machine = unsafe { &mut *(handle as *mut scryer_prolog::Machine) };
    let escaped = tmp_path.to_str().unwrap_or("").replace('\'', "\\'");
    let query = format!("consult('{escaped}').");

    let result = with_suppressed_panics(AssertUnwindSafe(|| {
        machine.run_query(&query).next().map_or(0i32, |answer| {
            if matches!(
                answer,
                Ok(LeafAnswer::True) | Ok(LeafAnswer::LeafAnswer { .. })
            ) {
                0
            } else {
                -1
            }
        })
    }))
    .unwrap_or(-1);

    let _ = std::fs::remove_file(&tmp_path);
    result
}

#[no_mangle]
pub extern "C" fn prolog_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn free_string_null_is_safe() {
        prolog_free_string(std::ptr::null_mut());
    }

    #[test]
    fn init_returns_non_null_handle() {
        let handle = prolog_init();
        assert!(!handle.is_null());
        prolog_deinit(handle);
    }

    #[test]
    fn query_returns_valid_json_array() {
        let handle = prolog_init();
        let goal = CString::new("member(X, [1,2,3])").unwrap();
        let result = prolog_query(handle, goal.as_ptr());
        assert!(!result.is_null());
        let json = unsafe { CStr::from_ptr(result).to_str().unwrap() };
        let parsed: serde_json::Value = serde_json::from_str(json).unwrap();
        assert!(parsed.is_array());
        prolog_free_string(result);
        prolog_deinit(handle);
    }

    #[test]
    fn assert_clause_returns_zero_on_success() {
        let handle = prolog_init();
        let clause = CString::new("foo(bar)").unwrap();
        assert_eq!(prolog_assert(handle, clause.as_ptr()), 0);
        prolog_deinit(handle);
    }

    #[test]
    fn load_string_returns_zero_on_success() {
        let handle = prolog_init();
        let source = CString::new(":- use_module(library(lists)).").unwrap();
        assert_eq!(prolog_load_string(handle, source.as_ptr()), 0);
        prolog_deinit(handle);
    }

    #[test]
    fn retract_asserted_clause_returns_zero() {
        let handle = prolog_init();
        let clause = CString::new("foo(bar)").unwrap();
        prolog_assert(handle, clause.as_ptr());
        let retract_term = CString::new("foo(bar)").unwrap();
        assert_eq!(prolog_retract(handle, retract_term.as_ptr()), 0);
        prolog_deinit(handle);
    }

    #[test]
    fn load_file_missing_path_returns_nonzero() {
        let handle = prolog_init();
        let path = CString::new("/nonexistent/path/file.pl").unwrap();
        assert_ne!(prolog_load_file(handle, path.as_ptr()), 0);
        prolog_deinit(handle);
    }

    #[test]
    fn retractall_asserted_facts_returns_zero() {
        let handle = prolog_init();
        let clause1 = CString::new("likes(alice, bob)").unwrap();
        let clause2 = CString::new("likes(alice, carol)").unwrap();
        prolog_assert(handle, clause1.as_ptr());
        prolog_assert(handle, clause2.as_ptr());
        let head = CString::new("likes(alice, _)").unwrap();
        assert_eq!(prolog_retractall(handle, head.as_ptr()), 0);
        prolog_deinit(handle);
    }

    #[test]
    fn retractall_null_handle_returns_minus_one() {
        let head = CString::new("foo(_)").unwrap();
        assert_eq!(prolog_retractall(std::ptr::null_mut(), head.as_ptr()), -1);
    }
}
