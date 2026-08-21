"""Odoo Attendance automation using Selenium WebDriver.

- Opens Chrome
- Logs into Odoo
- Navigates to Attendance module
- Creates attendance records for today based on the weekly schedule:
    Mon-Thu: 09:00-14:00, 15:00-18:30
    Fri:     09:00-15:00
    Sat-Sun: nothing
"""

from __future__ import annotations

import os
import sys
import time
from datetime import datetime, date
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse

from dotenv import load_dotenv
from selenium import webdriver
from selenium.common.exceptions import (
    ElementNotInteractableException,
    NoSuchElementException,
    TimeoutException,
    WebDriverException,
)
from selenium.webdriver import ChromeOptions
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait

try:  # Python 3.11+
    import tomllib
except ModuleNotFoundError:  # Python 3.10
    import tomli as tomllib  # type: ignore[no-redef]

# ---------------------------------------------------------------------------
# Configuration: all settings live in config.toml (no code edits needed).
# A built-in default is used only as a fallback when config.toml is absent.
# weekday(): 0=Monday … 6=Sunday. Times use HH:MM (float_time widget in Odoo).
# ---------------------------------------------------------------------------

CONFIG_PATH = Path(__file__).resolve().parent / "config.toml"

# Fallback schedule (mirrors config.example.toml). Used ONLY if config.toml
# is missing, so the script never hard-crashes during a first-time setup.
_FALLBACK_CONFIG: dict = {
    "odoo": {"headless": False, "user_data_dir": ""},
    "behavior": {"skip_weekdays": [5, 6]},
    "schedule": {
        "summer_months": [7, 8],
        "summer": {
            "0": [("08:00", "15:00", "Trabajo")],
            "1": [("08:00", "15:00", "Trabajo")],
            "2": [("08:00", "15:00", "Trabajo")],
            "3": [("08:00", "15:00", "Trabajo")],
            "4": [("08:00", "14:00", "Trabajo")],
            "5": [],
            "6": [],
        },
        "normal": {
            "0": [("09:00", "14:00", "Trabajo"), ("14:00", "15:00", "Descanso"), ("15:00", "18:50", "Trabajo")],
            "1": [("09:00", "14:00", "Trabajo"), ("14:00", "15:00", "Descanso"), ("15:00", "18:50", "Trabajo")],
            "2": [("09:00", "14:00", "Trabajo"), ("14:00", "15:00", "Descanso"), ("15:00", "18:50", "Trabajo")],
            "3": [("09:00", "14:00", "Trabajo"), ("14:00", "15:00", "Descanso"), ("15:00", "18:50", "Trabajo")],
            "4": [("09:00", "15:00", "Trabajo")],
            "5": [],
            "6": [],
        },
        "special_days": {
            "12-24": [("08:00", "12:00", "Trabajo")],
            "12-31": [("08:00", "12:00", "Trabajo")],
        },
    },
}


def load_config() -> dict:
    """Load configuration from config.toml, falling back to .env + defaults."""
    if CONFIG_PATH.exists():
        with open(CONFIG_PATH, "rb") as fh:
            cfg = tomllib.load(fh)
        # Backward-compat: if [odoo] credentials are absent, try .env.
        odoo = cfg.setdefault("odoo", {})
        _load_env()
        odoo.setdefault("url", os.getenv("ODOO_URL", ""))
        odoo.setdefault("username", os.getenv("ODOO_USERNAME", ""))
        odoo.setdefault("password", os.getenv("ODOO_PASSWORD", ""))
        odoo.setdefault("headless", os.getenv("ODOO_HEADLESS", "false").strip().lower() == "true")
        odoo.setdefault("user_data_dir", os.getenv("ODOO_USER_DATA_DIR", "") or "")
        return cfg
    # No config.toml: build from .env + built-in defaults.
    _load_env()
    cfg = {k: (v.copy() if isinstance(v, dict) else v) for k, v in _FALLBACK_CONFIG.items()}
    cfg["odoo"] = {
        "url": os.getenv("ODOO_URL", ""),
        "username": os.getenv("ODOO_USERNAME", ""),
        "password": os.getenv("ODOO_PASSWORD", ""),
        "headless": os.getenv("ODOO_HEADLESS", "false").strip().lower() == "true",
        "user_data_dir": os.getenv("ODOO_USER_DATA_DIR", "") or "",
    }
    return cfg


def create_driver(headless: bool = False, user_data_dir: Optional[str] = None) -> webdriver.Chrome:
    options = ChromeOptions()
    if headless:
        # Use the new headless mode for recent Chrome versions.
        options.add_argument("--headless=new")
    options.add_argument("--start-maximized")
    options.add_argument("--disable-gpu")
    options.add_argument("--no-sandbox")

    if user_data_dir:
        options.add_argument(f"--user-data-dir={user_data_dir}")

    service = Service()
    return webdriver.Chrome(service=service, options=options)


def _set_input_value(driver: webdriver.Chrome, element: webdriver.remote.webelement.WebElement, value: str) -> None:
    driver.execute_script(
        "arguments[0].value = arguments[1];"
        "arguments[0].dispatchEvent(new Event('input', {bubbles: true}));"
        "arguments[0].dispatchEvent(new Event('change', {bubbles: true}));",
        element,
        value,
    )


def login(driver: webdriver.Chrome, url: str, username: str, password: str, timeout: int = 20) -> None:
    # Build a list of candidate URLs to try. Odoo instances sometimes need
    # /web/login or a /odoo prefix; if the raw URL doesn't show a login form,
    # we try these alternatives before giving up.
    parsed = urlparse(url)
    base = f"{parsed.scheme}://{parsed.netloc}"
    path = parsed.path.rstrip("/")
    candidates = []
    if path:
        candidates.append(f"{base}{path}")
        candidates.append(f"{base}{path}/web/login")
    candidates.append(f"{base}/web/login")
    candidates.append(url)
    # De-duplicate while preserving order
    seen = set()
    candidates = [c for c in candidates if not (c in seen or seen.add(c))]

    wait = WebDriverWait(driver, timeout)
    email_input = None
    password_input = None
    last_url = url

    for candidate in candidates:
        last_url = candidate
        driver.get(candidate)
        try:
            email_input = wait.until(EC.visibility_of_element_located((By.NAME, "login")))
            password_input = wait.until(EC.visibility_of_element_located((By.NAME, "password")))
            break
        except TimeoutException:
            continue

    if email_input is None or password_input is None:
        raise RuntimeError(
            f"Login form did not load. Tried URLs: {', '.join(candidates)}"
        )

    try:
        email_input.click()
        email_input.clear()
        email_input.send_keys(username)
    except ElementNotInteractableException:
        _set_input_value(driver, email_input, username)

    try:
        password_input.click()
        password_input.clear()
        password_input.send_keys(password)
        password_input.send_keys(Keys.ENTER)
    except ElementNotInteractableException:
        _set_input_value(driver, password_input, password)
        try:
            submit_button = wait.until(
                EC.element_to_be_clickable((By.CSS_SELECTOR, "button[type='submit'], button.oe_login_buttons"))
            )
            submit_button.click()
        except TimeoutException as exc:
            raise RuntimeError("Login submit button not available.") from exc

    # Confirm login by waiting for the web client to load
    try:
        wait.until(EC.presence_of_element_located((By.CSS_SELECTOR, "body.o_web_client")))
    except TimeoutException as exc:
        raise RuntimeError("Login failed or dashboard did not load.") from exc


def _get_base_url(url: str) -> str:
    """Extract scheme + host (+ optional path prefix like /odoo) for building URLs."""
    parsed = urlparse(url)
    if not parsed.scheme or not parsed.netloc:
        raise RuntimeError("Invalid ODOO_URL. Example: https://miempresa.odoo.com")
    # Keep the path prefix (e.g. /odoo) if it exists, stripping trailing slashes
    prefix = parsed.path.rstrip("/")
    return f"{parsed.scheme}://{parsed.netloc}{prefix}"


def go_to_attendance(driver: webdriver.Chrome, base_url: str, timeout: int = 20) -> None:
    """Navigate to the Attendance module and wait until it's loaded."""
    wait = WebDriverWait(driver, timeout)

    # Try direct URL — build it from scheme + host to avoid path issues
    parsed = urlparse(base_url)
    direct_url = f"{parsed.scheme}://{parsed.netloc}/odoo/attendances"
    driver.get(direct_url)
    time.sleep(2)

    # Check if we landed on the attendance view (Gantt or List)
    try:
        wait.until(
            EC.any_of(
                EC.presence_of_element_located((By.CSS_SELECTOR, ".o_gantt_view")),
                EC.presence_of_element_located((By.CSS_SELECTOR, ".o_list_view")),
                EC.presence_of_element_located((By.CSS_SELECTOR, ".o_attendance_plus_gantt_view")),
                EC.presence_of_element_located(
                    (By.XPATH, "//span[@class='o_menu_brand' and contains(text(), 'Asistencias')]"
                     " | //span[contains(@class, 'o_menu_brand') and contains(text(), 'Asistencias')]")
                ),
            )
        )
        return
    except TimeoutException:
        # Fallback to manual menu navigation
        pass

    try:
        # Open the home / Apps menu
        apps_menu = wait.until(
            EC.element_to_be_clickable(
                (By.CSS_SELECTOR, "a.o_menu_toggle")
            )
        )
        apps_menu.click()
        time.sleep(2)

        # Look for Asistencias app icon/link
        attendance_app = wait.until(
            EC.element_to_be_clickable(
                (By.XPATH,
                 "//a[contains(@class,'o_app')]//span[contains(normalize-space(.), 'Asistencias')]/.. "
                 "| //a[contains(normalize-space(.), 'Asistencias')]")
            )
        )
        attendance_app.click()
        time.sleep(3)
    except (TimeoutException, NoSuchElementException) as exc:
        raise RuntimeError("Could not navigate to Attendance module.") from exc


def _load_env() -> None:
    # Load from .env if present, otherwise rely on real environment variables.
    env_path = Path(".env")
    if env_path.exists():
        load_dotenv(dotenv_path=env_path)
    else:
        load_dotenv()


# ---------------------------------------------------------------------------
# Get today's schedule blocks
# ---------------------------------------------------------------------------
def get_today_blocks(target_date: date | None = None, config: dict | None = None) -> list[tuple[str, str, str]]:
    """Return list of (check_in, check_out, category) for the given date.

    Schedule logic (all driven by config.toml):
    - Special days ("MM-DD") override everything.
    - Months listed in schedule.summer_months use the summer schedule.
    - Otherwise the normal schedule applies.
    - Weekday keys are strings ("0".."6") because TOML parses bare numeric
      keys as strings.
    """
    if target_date is None:
        target_date = date.today()
    if config is None:
        config = load_config()

    sched = config.get("schedule", {})

    # Special days take precedence
    key = f"{target_date.month:02d}-{target_date.day:02d}"
    special = sched.get("special_days", {})
    if key in special:
        return [tuple(b) for b in special[key]]

    summer_months = sched.get("summer_months", [])
    day_map = sched.get("summer", {}) if target_date.month in summer_months else sched.get("normal", {})
    blocks = day_map.get(str(target_date.weekday()), [])
    return [tuple(b) for b in blocks]


# ---------------------------------------------------------------------------
# Clear an Odoo input field reliably, then type a value
# ---------------------------------------------------------------------------
def _clear_and_type(driver: webdriver.Chrome, element, value: str) -> None:
    """Select all text and replace it with *value*."""
    element.click()
    element.send_keys(Keys.CONTROL, "a")
    element.send_keys(value)
    element.send_keys(Keys.TAB)
    time.sleep(0.1)


# ---------------------------------------------------------------------------
# Select a value in a many2one autocomplete field
# ---------------------------------------------------------------------------
def _select_many2one(driver: webdriver.Chrome, field_input, value: str, timeout: int = 10) -> None:
    """Type into a many2one autocomplete and pick the matching dropdown option."""
    wait = WebDriverWait(driver, timeout)
    field_input.click()
    field_input.send_keys(Keys.CONTROL, "a")
    field_input.send_keys(value)
    time.sleep(0.4)  # wait for autocomplete dropdown

    # Click the matching dropdown option
    try:
        option = wait.until(
            EC.element_to_be_clickable(
                (By.XPATH,
                 f"//ul[contains(@class,'o-autocomplete')]/li//a[contains(normalize-space(.), '{value}')] "
                 f"| //ul[contains(@class,'ui-autocomplete')]/li//a[contains(normalize-space(.), '{value}')] "
                 f"| //div[contains(@class,'o-autocomplete--dropdown')]//*[contains(normalize-space(.), '{value}')] "
                 f"| //ul[@role='listbox']//a[contains(normalize-space(.), '{value}')]")
            )
        )
        option.click()
    except TimeoutException:
        field_input.send_keys(Keys.ENTER)
    time.sleep(0.15)


# ---------------------------------------------------------------------------
# Add a single day-block row inside the one2many "Bloques de día" table
# ---------------------------------------------------------------------------
def _add_day_block(
    driver: webdriver.Chrome,
    check_in: str,
    check_out: str,
    category: str,
    timeout: int = 15,
) -> None:
    """Click 'Añadir una línea', fill check_in_time, check_out_time, category_id."""
    wait = WebDriverWait(driver, timeout)

    # Click "Añadir una línea" inside the day_block_ids one2many
    add_link = wait.until(
        EC.element_to_be_clickable(
            (By.XPATH,
             "//div[@name='day_block_ids']//a[contains(normalize-space(.), 'Añadir') "
             "or contains(normalize-space(.), 'Add a line')]")
        )
    )
    add_link.click()
    time.sleep(0.4)

    # The new row should now be the last <tr> in the tbody with editable cells.
    # Find the last row's cells for check_in_time, check_out_time, category_id.
    rows = driver.find_elements(
        By.CSS_SELECTOR,
        "div[name='day_block_ids'] tbody tr.o_data_row"
    )
    if not rows:
        # Fallback: maybe the row is selected/active
        rows = driver.find_elements(
            By.CSS_SELECTOR,
            "div[name='day_block_ids'] tbody tr.o_selected_row"
        )
    if not rows:
        raise RuntimeError("Could not find the new day-block row after clicking 'Añadir una línea'.")

    new_row = rows[-1]

    # --- Entrada (check_in_time) ---
    try:
        cin_cell = new_row.find_element(By.CSS_SELECTOR, "td[name='check_in_time'], td.o_float_time_cell")
        cin_cell.click()
        time.sleep(0.1)
        cin_input = new_row.find_element(
            By.CSS_SELECTOR,
            "td[name='check_in_time'] input, td:nth-child(1) input"
        )
    except NoSuchElementException:
        cells = new_row.find_elements(By.TAG_NAME, "td")
        cells[0].click()
        time.sleep(0.1)
        cin_input = new_row.find_element(By.CSS_SELECTOR, "input")

    _clear_and_type(driver, cin_input, check_in)

    # --- Salida (check_out_time) ---
    try:
        cout_cell = new_row.find_element(By.CSS_SELECTOR, "td[name='check_out_time']")
        cout_cell.click()
        time.sleep(0.1)
        cout_input = new_row.find_element(By.CSS_SELECTOR, "td[name='check_out_time'] input")
    except NoSuchElementException:
        cells = new_row.find_elements(By.TAG_NAME, "td")
        cells[1].click()
        time.sleep(0.1)
        cout_input = cells[1].find_element(By.CSS_SELECTOR, "input")

    _clear_and_type(driver, cout_input, check_out)

    # --- Categoría (category_id) ---
    try:
        cat_cell = new_row.find_element(By.CSS_SELECTOR, "td[name='category_id']")
        cat_cell.click()
        time.sleep(0.1)
        cat_input = new_row.find_element(By.CSS_SELECTOR, "td[name='category_id'] input")
    except NoSuchElementException:
        cells = new_row.find_elements(By.TAG_NAME, "td")
        cells[2].click()
        time.sleep(0.1)
        cat_input = cells[2].find_element(By.CSS_SELECTOR, "input")

    _select_many2one(driver, cat_input, category)
    print(f"    Block done: {check_in}-{check_out} [{category}]")


# ---------------------------------------------------------------------------
# Create the attendance record with all day blocks for today
# ---------------------------------------------------------------------------
def create_today_attendance(driver: webdriver.Chrome, timeout: int = 20) -> int:
    """Click New on the already-open attendance view, add day blocks, save."""
    wait = WebDriverWait(driver, timeout)
    blocks = get_today_blocks(config=load_config())
    if not blocks:
        return 0

    # 1) Click "Nuevo" / "New" — works on Gantt, List, or any attendance view
    try:
        new_btn = wait.until(
            EC.element_to_be_clickable(
                (By.CSS_SELECTOR,
                 "button.o_gantt_button_add, "
                 "button.o_list_button_add, "
                 ".o_cp_buttons button.btn-primary")
            )
        )
        new_btn.click()
    except TimeoutException:
        new_btn = wait.until(
            EC.element_to_be_clickable(
                (By.XPATH,
                 "//button[contains(normalize-space(.), 'Nuevo') or "
                 "contains(normalize-space(.), 'New')]")
            )
        )
        new_btn.click()
    time.sleep(1.5)

    # 2) Verify we are in the form view
    wait.until(EC.presence_of_element_located((By.CSS_SELECTOR, "div.o_form_renderer")))
    print("  Form opened successfully.")

    # 3) Select the employee (first/only option in the autocomplete)
    try:
        emp_input = wait.until(
            EC.presence_of_element_located(
                (By.CSS_SELECTOR,
                 "div[name='employee_id'] input, "
                 ".o_field_widget[name='employee_id'] input")
            )
        )
        emp_input.click()
        time.sleep(0.2)
        current_val = emp_input.get_attribute("value") or ""
        if not current_val.strip():
            emp_input.send_keys(Keys.BACKSPACE)
            time.sleep(0.4)
            try:
                first_option = wait.until(
                    EC.element_to_be_clickable(
                        (By.CSS_SELECTOR,
                         "ul.o-autocomplete--dropdown-menu li a, "
                         ".o-autocomplete--dropdown-menu a, "
                         "ul[role='listbox'] li a")
                    )
                )
                first_option.click()
            except TimeoutException:
                emp_input.send_keys(Keys.ARROW_DOWN)
                emp_input.send_keys(Keys.ENTER)
            time.sleep(0.2)
            print("  Employee selected.")
        else:
            print(f"  Employee already set: {current_val}")
    except TimeoutException:
        print("  WARNING: Could not find employee_id field.")

    # 4) Add each day block
    for i, (cin, cout, cat) in enumerate(blocks):
        print(f"  Adding block {i + 1}/{len(blocks)}: {cin} - {cout} ({cat})")
        _add_day_block(driver, cin, cout, cat)

    print("  All blocks added. Saving...")

    # 5) Save immediately — click as fast as possible, no extra delays
    try:
        # First try clicking outside the table to deselect the active row
        form_area = driver.find_element(By.CSS_SELECTOR, "div.o_form_renderer")
        form_area.click()
        time.sleep(0.2)
    except Exception:
        pass

    saved = False
    # Method 1: CSS selector
    try:
        save_btn = WebDriverWait(driver, 5).until(
            EC.element_to_be_clickable(
                (By.CSS_SELECTOR,
                 "button.o_form_button_save, "
                 ".o_cp_buttons button.o_form_button_save, "
                 ".o_statusbar_buttons button.o_form_button_save")
            )
        )
        save_btn.click()
        saved = True
    except (TimeoutException, NoSuchElementException):
        pass

    # Method 2: XPath text search
    if not saved:
        try:
            save_btn = WebDriverWait(driver, 5).until(
                EC.element_to_be_clickable(
                    (By.XPATH,
                     "//button[contains(normalize-space(.), 'Guardar') or "
                     "contains(normalize-space(.), 'Save')]")
                )
            )
            save_btn.click()
            saved = True
        except (TimeoutException, NoSuchElementException):
            pass

    # Method 3: Use keyboard shortcut (Ctrl+S) or breadcrumb discard
    if not saved:
        try:
            print("  Attempting Ctrl+S to save...")
            from selenium.webdriver.common.action_chains import ActionChains
            ActionChains(driver).key_down(Keys.CONTROL).send_keys('s').key_up(Keys.CONTROL).perform()
            saved = True
        except Exception:
            pass

    if saved:
        time.sleep(0.5)
        print("  Record saved.")
    else:
        print("  WARNING: Could not find/click save button.")

    return len(blocks)


def main() -> int:
    config = load_config()
    odoo = config.get("odoo", {})

    url = str(odoo.get("url", "")).strip()
    username = str(odoo.get("username", "")).strip()
    password = str(odoo.get("password", "")).strip()
    headless = bool(odoo.get("headless", False))
    user_data_dir = str(odoo.get("user_data_dir", "")).strip() or None

    if not url or not username or not password:
        print("Missing odoo.url, odoo.username, or odoo.password in config.toml.")
        return 1

    try:
        base_url = _get_base_url(url)
        driver = create_driver(headless=headless, user_data_dir=user_data_dir)
    except (RuntimeError, WebDriverException) as exc:
        print(str(exc))
        return 1

    try:
        print("Opening Odoo login page...")
        login(driver, url, username, password)
        print("Login successful.")
        print("Navigating to Attendance module...")
        go_to_attendance(driver, base_url)
        print("Attendance module loaded.")

        today = date.today()
        weekday_name = ["Lunes", "Martes", "Miercoles", "Jueves",
                        "Viernes", "Sabado", "Domingo"][today.weekday()]
        blocks = get_today_blocks(config=config)

        if not blocks:
            print(f"Hoy es {weekday_name} - no hay fichajes programados.")
        else:
            print(f"Hoy es {weekday_name} - {len(blocks)} bloque(s) a registrar:")
            for cin, cout, cat in blocks:
                print(f"  {cin} - {cout}  [{cat}]")
            count = create_today_attendance(driver)
            print(f"{count} bloque(s) de asistencia creados correctamente.")

        print("Browser will remain open for manual review.")
        return 0
    except Exception as exc:
        print(f"ERROR: {type(exc).__name__}: {exc}")
        return 1


# ---------------------------------------------------------------------------
# JSON-RPC helpers (used by fichaje en masa — much faster than UI navigation)
# ---------------------------------------------------------------------------
_RPC_CATEGORY_MAP: dict[str, int] | None = None
_RPC_EMPLOYEE_ID: int | None = None


def _get_rpc_session(driver: webdriver.Chrome) -> "requests.Session":
    """Build a requests.Session with cookies copied from the Selenium driver."""
    import requests as _requests
    session = _requests.Session()
    for cookie in driver.get_cookies():
        session.cookies.set(cookie["name"], cookie["value"])
    return session


# Detect the local timezone once (used to tell Odoo how to interpret datetimes).
try:
    from datetime import timezone as _dt_tz, timedelta as _dt_td
    _local_now = datetime.now().astimezone()
    _LOCAL_TZ = str(_local_now.tzinfo) if _local_now.tzinfo else "UTC"
except Exception:
    _LOCAL_TZ = "Europe/Madrid"


def _rpc_call(session: "requests.Session", base_url: str, model: str,
              method: str, args: list | None = None,
              kwargs: dict | None = None) -> object:
    """Make a single JSON-RPC ``call_kw`` request to Odoo.

    Automatically injects ``context.tz`` so that datetime values are
    interpreted in the local timezone.
    """
    import requests as _requests
    kwargs = dict(kwargs or {})
    ctx = dict(kwargs.get("context", {}))
    if "tz" not in ctx:
        ctx["tz"] = _LOCAL_TZ
    kwargs["context"] = ctx

    payload = {
        "jsonrpc": "2.0",
        "method": "call",
        "params": {
            "model": model,
            "method": method,
            "args": args or [],
            "kwargs": kwargs,
        },
        "id": 1,
    }
    parsed = urlparse(base_url)
    kw_url = f"{parsed.scheme}://{parsed.netloc}/web/dataset/call_kw"
    r = session.post(kw_url, json=payload, timeout=30)
    r.raise_for_status()
    body = r.json()
    if "error" in body:
        msg = body["error"]["data"].get("message", str(body["error"]))
        raise RuntimeError(f"Odoo RPC error: {msg}")
    return body.get("result")


def _rpc_resolve_categories(session: "requests.Session", base_url: str) -> dict[str, int]:
    """Return ``{category_name: category_id}`` from the Odoo instance."""
    global _RPC_CATEGORY_MAP
    if _RPC_CATEGORY_MAP is not None:
        return _RPC_CATEGORY_MAP
    cats = _rpc_call(session, base_url, "hr.attendance.category",
                     "search_read", [], {"fields": ["id", "name"]})
    _RPC_CATEGORY_MAP = {c["name"]: c["id"] for c in (cats or [])}
    return _RPC_CATEGORY_MAP


def _rpc_resolve_employee(session: "requests.Session", base_url: str,
                          username: str = "") -> int:
    """Return the employee id for the logged-in user (no hardcoded IDs).

    Tries, in order:
      1. ``hr.employee`` by ``work_email`` matching *username*.
      2. ``res.users`` search to find the current user's ``employee_ids``.
      3. Fallback: first employee (last resort).
    """
    global _RPC_EMPLOYEE_ID
    if _RPC_EMPLOYEE_ID is not None:
        return _RPC_EMPLOYEE_ID

    # Strategy 1: search hr.employee by work_email (most reliable)
    if username and "@" in username:
        try:
            emp = _rpc_call(session, base_url, "hr.employee", "search_read",
                            [[["work_email", "=ilike", username]]],
                            {"fields": ["id"], "limit": 1})
            if emp:
                _RPC_EMPLOYEE_ID = emp[0]["id"]
                return _RPC_EMPLOYEE_ID
        except Exception:
            pass

    # Strategy 2: res.users -> employee_ids
    try:
        users = _rpc_call(session, base_url, "res.users", "search_read",
                          [], {"fields": ["id", "login", "employee_ids"]})
        # Find the user whose login matches *username*, or pick any with an employee
        for u in (users or []):
            if username and u.get("login") == username and u.get("employee_ids"):
                _RPC_EMPLOYEE_ID = u["employee_ids"][0]
                return _RPC_EMPLOYEE_ID
        # Fallback: first user that has an employee linked
        for u in (users or []):
            if u.get("employee_ids"):
                _RPC_EMPLOYEE_ID = u["employee_ids"][0]
                return _RPC_EMPLOYEE_ID
    except Exception:
        pass

    # Strategy 3: last resort — first employee
    emp = _rpc_call(session, base_url, "hr.employee", "search_read",
                    [], {"fields": ["id"], "limit": 1})
    _RPC_EMPLOYEE_ID = emp[0]["id"] if emp else 1
    return _RPC_EMPLOYEE_ID


def _time_to_float(t_str: str) -> float:
    """Convert 'HH:MM' to float hours (e.g. '09:30' -> 9.5)."""
    h, m = t_str.split(":")
    return float(h) + float(m) / 60.0


def _rpc_create_attendance(
    session: "requests.Session",
    base_url: str,
    target_date: date,
    blocks: list[tuple[str, str, str]],
    username: str = "",
) -> int:
    """Create one attendance record with day-blocks via JSON-RPC.

    Returns the number of blocks created (0 if no blocks, raises on error).
    """
    if not blocks:
        return 0

    cat_map = _rpc_resolve_categories(session, base_url)
    employee_id = _rpc_resolve_employee(session, base_url, username=username)
    date_str = target_date.strftime("%Y-%m-%d")

    # 1. Create day-block records.
    #    Odoo derives the attendance *date* from check_in/check_out datetimes,
    #    so we must supply them.  The tz context (injected by _rpc_call) ensures
    #    Odoo interprets the naive datetimes in the local timezone.
    day_block_ids: list[int] = []
    created_blocks: list[int] = []
    try:
        for cin, cout, cat_name in blocks:
            cat_id = cat_map.get(cat_name, 1)
            block_vals = {
                "check_in_time": _time_to_float(cin),
                "check_out_time": _time_to_float(cout),
                "category_id": cat_id,
                "check_in": f"{date_str} {cin}:00",
                "check_out": f"{date_str} {cout}:00",
            }
            bid = _rpc_call(session, base_url, "hr.attendance.day.block",
                            "create", [block_vals])
            day_block_ids.append(bid)
            created_blocks.append(bid)

        # 2. Create the attendance record linking the blocks.
        first_cat = cat_map.get(blocks[0][2], 1)
        vals = {
            "employee_id": employee_id,
            "check_in": f"{date_str} {blocks[0][0]}:00",
            "check_out": f"{date_str} {blocks[-1][1]}:00",
            "category_id": first_cat,
            "day_block_ids": [(6, 0, day_block_ids)],
        }
        _rpc_call(session, base_url, "hr.attendance", "create", [vals])
        return len(blocks)
    except Exception:
        # Clean up any orphan day-blocks
        for bid in created_blocks:
            try:
                _rpc_call(session, base_url, "hr.attendance.day.block",
                          "unlink", [[bid]])
            except Exception:
                pass
        raise


# ---------------------------------------------------------------------------
# Fichaje en masa (via JSON-RPC)
# ---------------------------------------------------------------------------
def run_bulk(start_date: date, end_date: date, config: dict | None = None,
             excluded_dates: set[date] | None = None) -> int:
    """Ficha todos los dias laborables entre *start_date* y *end_date*.

    Usa la API JSON-RPC de Odoo (no el navegador) para crear cada registro,
    lo que es mucho mas rapido y fiable que navegar el gantt.
    """
    if excluded_dates is None:
        excluded_dates = set()
    if config is None:
        config = load_config()
    odoo = config.get("odoo", {})
    url = str(odoo.get("url", "")).strip()
    username = str(odoo.get("username", "")).strip()
    password = str(odoo.get("password", "")).strip()
    headless = bool(odoo.get("headless", False))
    user_data_dir = str(odoo.get("user_data_dir", "")).strip() or None

    if not url or not username or not password:
        print("Missing odoo.url, odoo.username, or odoo.password in config.toml.")
        return 1

    if start_date > end_date:
        print("La fecha de inicio no puede ser posterior a la fecha de fin.")
        return 1

    # Build the list of days to process
    skip_weekdays = set(config.get("behavior", {}).get("skip_weekdays", []))
    days_to_process: list[tuple[date, list[tuple[str, str, str]]]] = []
    skipped_excluded = 0
    current = start_date
    from datetime import timedelta
    while current <= end_date:
        if current in excluded_dates:
            skipped_excluded += 1
        elif current.weekday() not in skip_weekdays:
            blocks = get_today_blocks(current, config)
            if blocks:
                days_to_process.append((current, blocks))
        current += timedelta(days=1)

    if not days_to_process:
        print("No hay dias con fichajes programados en el rango seleccionado.")
        return 0

    msg = f"Fichaje en masa: {len(days_to_process)} dia(s) a registrar"
    if skipped_excluded:
        msg += f" ({skipped_excluded} excluidos)"
    msg += f" entre {start_date} y {end_date}."
    print(msg)

    try:
        base_url = _get_base_url(url)
        driver = create_driver(headless=headless, user_data_dir=user_data_dir)
    except (RuntimeError, WebDriverException) as exc:
        print(str(exc))
        return 1

    success_count = 0
    fail_count = 0
    try:
        print("Opening Odoo login page...")
        login(driver, url, username, password)
        print("Login successful.")

        # Build RPC session from the authenticated browser cookies
        import requests as _requests
        rpc_sess = _get_rpc_session(driver)
        print("RPC session ready.")

        for i, (target_date, blocks) in enumerate(days_to_process, 1):
            weekday_name = ["Lunes", "Martes", "Miercoles", "Jueves",
                            "Viernes", "Sabado", "Domingo"][target_date.weekday()]
            print(f"\n--- [{i}/{len(days_to_process)}] {target_date} ({weekday_name}) ---")
            print(f"  {len(blocks)} bloque(s): " + ", ".join(f"{b[0]}-{b[1]} [{b[2]}]" for b in blocks))

            try:
                count = _rpc_create_attendance(rpc_sess, base_url, target_date, blocks, username=username)
                print(f"  OK: {count} bloque(s) creados via RPC.")
                success_count += 1
            except Exception as exc:
                print(f"  ERROR: {type(exc).__name__}: {exc}")
                fail_count += 1
                continue

        print(f"\n=== Fichaje en masa completado ===")
        print(f"  Exitosos: {success_count}")
        print(f"  Fallidos: {fail_count}")
        print(f"  Total procesados: {len(days_to_process)}")
        return 0 if fail_count == 0 else 1
    except Exception as exc:
        print(f"ERROR: {type(exc).__name__}: {exc}")
        return 1


# ---------------------------------------------------------------------------
# Single-day UI-based creation (kept as fallback for "Fichar ahora" button)
# ---------------------------------------------------------------------------
def create_today_attendance_for_date(
    driver: webdriver.Chrome,
    target_date: date,
    blocks: list[tuple[str, str, str]],
    base_url: str = "",
    timeout: int = 20,
) -> int:
    """Create an attendance record for a specific date using the UI.

    Used as a fallback when the RPC approach is not available.
    Navigates the gantt to *target_date* and clicks New.
    """
    if not blocks:
        return 0

    wait = WebDriverWait(driver, timeout)

    # Navigate to attendance page
    if base_url:
        parsed = urlparse(base_url)
        driver.get(f"{parsed.scheme}://{parsed.netloc}/odoo/attendances")
        time.sleep(2)

    # Click "Nuevo" / "New"
    try:
        new_btn = wait.until(
            EC.element_to_be_clickable(
                (By.CSS_SELECTOR,
                 "button.o_gantt_button_add, "
                 "button.o_list_button_add, "
                 ".o_cp_buttons button.btn-primary")
            )
        )
        new_btn.click()
    except TimeoutException:
        new_btn = wait.until(
            EC.element_to_be_clickable(
                (By.XPATH,
                 "//button[contains(normalize-space(.), 'Nuevo') or "
                 "contains(normalize-space(.), 'New')]")
            )
        )
        new_btn.click()
    time.sleep(1.5)

    wait.until(EC.presence_of_element_located((By.CSS_SELECTOR, "div.o_form_renderer")))

    # Select employee (first/only option)
    try:
        emp_input = wait.until(
            EC.presence_of_element_located(
                (By.CSS_SELECTOR,
                 "div[name='employee_id'] input, "
                 ".o_field_widget[name='employee_id'] input")
            )
        )
        emp_input.click()
        time.sleep(0.2)
        current_val = emp_input.get_attribute("value") or ""
        if not current_val.strip():
            emp_input.send_keys(Keys.BACKSPACE)
            time.sleep(0.4)
            try:
                first_option = wait.until(
                    EC.element_to_be_clickable(
                        (By.CSS_SELECTOR,
                         "ul.o-autocomplete--dropdown-menu li a, "
                         ".o-autocomplete--dropdown-menu a, "
                         "ul[role='listbox'] li a")
                    )
                )
                first_option.click()
            except TimeoutException:
                emp_input.send_keys(Keys.ARROW_DOWN)
                emp_input.send_keys(Keys.ENTER)
            time.sleep(0.2)
    except TimeoutException:
        pass

    # Add each day block
    for cin, cout, cat in blocks:
        _add_day_block(driver, cin, cout, cat)

    # Save
    try:
        form_area = driver.find_element(By.CSS_SELECTOR, "div.o_form_renderer")
        form_area.click()
        time.sleep(0.2)
    except Exception:
        pass

    saved = False
    try:
        save_btn = WebDriverWait(driver, 5).until(
            EC.element_to_be_clickable(
                (By.CSS_SELECTOR,
                 "button.o_form_button_save, "
                 ".o_cp_buttons button.o_form_button_save, "
                 ".o_statusbar_buttons button.o_form_button_save")
            )
        )
        save_btn.click()
        saved = True
    except (TimeoutException, NoSuchElementException):
        pass

    if not saved:
        try:
            save_btn = WebDriverWait(driver, 5).until(
                EC.element_to_be_clickable(
                    (By.XPATH,
                     "//button[contains(normalize-space(.), 'Guardar') or "
                     "contains(normalize-space(.), 'Save')]")
                )
            )
            save_btn.click()
            saved = True
        except (TimeoutException, NoSuchElementException):
            pass

    if not saved:
        try:
            from selenium.webdriver.common.action_chains import ActionChains
            ActionChains(driver).key_down(Keys.CONTROL).send_keys('s').key_up(Keys.CONTROL).perform()
            saved = True
        except Exception:
            pass

    if saved:
        time.sleep(0.5)

    return len(blocks)


if __name__ == "__main__":
    # Support: python odoo_attendance.py                          -> today's fichaje
    #          python odoo_attendance.py --bulk START END          -> bulk range
    #          python odoo_attendance.py --bulk START END --exclude D1,D2,...  -> bulk with exclusions
    if len(sys.argv) >= 4 and sys.argv[1] == "--bulk":
        from datetime import datetime as _dt
        try:
            start = _dt.strptime(sys.argv[2], "%Y-%m-%d").date()
            end = _dt.strptime(sys.argv[3], "%Y-%m-%d").date()
        except ValueError:
            print("Formato de fecha invalido. Usa YYYY-MM-DD (ej: 2026-08-01 2026-08-31).")
            sys.exit(1)
        excluded = set()
        if "--exclude" in sys.argv:
            try:
                idx = sys.argv.index("--exclude")
                raw = sys.argv[idx + 1]
                for part in raw.split(","):
                    part = part.strip()
                    if part:
                        excluded.add(_dt.strptime(part, "%Y-%m-%d").date())
            except (ValueError, IndexError):
                print("Formato de exclusion invalido. Usa YYYY-MM-DD separadas por comas.")
                sys.exit(1)
        sys.exit(run_bulk(start, end, excluded_dates=excluded))
    sys.exit(main())