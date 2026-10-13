"""Registry of the source files the pipeline ingests and where each one lands.

Each daily drop is named `<name>_<YYYY-MM-DD>.<csv|json>` in data/landing.
"""

from dataclasses import dataclass
from datetime import date
from typing import Literal


@dataclass(frozen=True)
class SourceSpec:
    """Contract for one source file: format, required columns and staging target(s)."""

    name: str
    file_format: Literal["csv", "json"]
    tables: dict[str, tuple[str, ...]]  # staging table -> columns loaded into it
    required: bool                       # a missing required file fails the run

    def filename(self, run_date: date) -> str:
        """Expected landing file name for a run date."""
        return f"{self.name}_{run_date.isoformat()}.{self.file_format}"


ORDER_COLUMNS = (
    "order_id", "customer_id", "restaurant_id", "delivery_partner_id", "payment_method_id",
    "order_datetime", "gross_amount", "discount", "delivery_fee", "net_amount",
    "delivery_minutes", "rating", "order_status",
)
ORDER_ITEM_COLUMNS = ("order_id", "item_id", "quantity", "unit_price")

SOURCES: dict[str, SourceSpec] = {spec.name: spec for spec in (
    SourceSpec("customers", "csv", {"stg_customers": (
        "customer_id", "customer_name", "email", "phone", "city", "state", "pincode", "signup_date")},
        required=False),
    SourceSpec("restaurants", "csv", {"stg_restaurants": (
        "restaurant_id", "name", "cuisine_type", "city", "area", "rating", "cost_for_two", "is_active_partner")},
        required=False),
    SourceSpec("menu_items", "csv", {"stg_menu_items": (
        "item_id", "restaurant_id", "item_name", "category", "is_veg", "base_price", "is_available")},
        required=False),
    SourceSpec("delivery_partners", "csv", {"stg_delivery_partners": (
        "partner_id", "partner_name", "phone", "vehicle_type", "city", "rating", "status")},
        required=False),
    SourceSpec("payment_methods", "csv", {"stg_payment_methods": (
        "payment_method_id", "method_name", "method_category")},
        required=False),
    # Orders arrive as JSON with nested items, flattened into two staging tables
    SourceSpec("orders", "json", {"stg_orders": ORDER_COLUMNS, "stg_order_items": ORDER_ITEM_COLUMNS},
               required=True),
)}
