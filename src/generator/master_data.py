"""Master data for the simulated food-delivery platform, as daily CSV snapshots.

The platform is generated once from a fixed seed and then viewed "as of" a
date, which makes the data change realistically from day to day:

* customers sign up over time and ~6% relocate to another city
  (drives SCD Type 2 history in dim_customer);
* restaurants join over time, ~20% revise their price band and some leave the
  platform (SCD Type 2 in dim_restaurant);
* ~10% of menu items get a price rise (SCD Type 1 in dim_menu_item).

Dirty data (~2-3% of rows) is injected in two ways, so cleansing can be shown
without creating false SCD2 history:

* entity-level defects (missing phone, invalid pincode, negative cost for two,
  rating 6.5) belong to a fixed set of entities and look the same every day;
* cosmetic defects (stray whitespace, wrong case) and duplicate rows vary by
  day, because cleansing removes them before change detection.
"""

import csv
import os
import random
import re
from dataclasses import dataclass, field
from datetime import date, timedelta
from functools import lru_cache
from pathlib import Path

from faker import Faker

from src.config import CALENDAR_END, CALENDAR_START
from src.generator.reference_data import (
    CITIES,
    CUISINE_MENUS,
    PAYMENT_METHODS,
    RESTAURANT_NAME_TEMPLATES,
    SEED,
    VEHICLE_TYPES,
    City,
)

FOUNDING_YEAR_START, FOUNDING_YEAR_END = date(2022, 1, 1), date(2022, 12, 31)
FOUNDING_CUSTOMERS, NEW_CUSTOMERS = 150, 650
FOUNDING_RESTAURANTS, NEW_RESTAURANTS = 42, 18
FOUNDING_PARTNERS, NEW_PARTNERS = 56, 34

ENTITY_DEFECT_RATE = 0.015    # per entity, stable across snapshots
COSMETIC_DEFECT_RATE = 0.012  # per row, varies by snapshot date
DUPLICATE_ROW_RATE = 0.006    # per row, varies by snapshot date


@dataclass(frozen=True)
class Customer:
    """A platform customer; the location changes if the customer relocates."""

    customer_id: str
    first_name: str
    last_name: str
    email: str
    phone: str
    signup_date: date
    home_city: City
    home_pincode: str
    order_weight: float
    relocation_date: date | None = None
    relocation_city: City | None = None
    relocation_pincode: str | None = None

    def location_on(self, day: date) -> tuple[City, str]:
        """City and pincode the customer lives at on the given day."""
        if self.relocation_date is not None and day >= self.relocation_date:
            return self.relocation_city, self.relocation_pincode
        return self.home_city, self.home_pincode


@dataclass(frozen=True)
class Restaurant:
    """A restaurant partner with an optional price revision and offboarding date."""

    restaurant_id: str
    name: str
    cuisine: str
    city: City
    area: str
    rating: float
    cost_for_two: int
    onboarded_date: date
    popularity: float
    price_revision_date: date | None = None
    revised_cost_for_two: int | None = None
    offboarded_date: date | None = None

    def is_listed_on(self, day: date) -> bool:
        """True once the restaurant has joined (it stays listed after leaving, as inactive)."""
        return self.onboarded_date <= day

    def is_active_on(self, day: date) -> bool:
        """True while the restaurant accepts orders."""
        return self.is_listed_on(day) and (self.offboarded_date is None or day < self.offboarded_date)

    def cost_on(self, day: date) -> int:
        """Cost for two in effect on the given day."""
        if self.price_revision_date is not None and day >= self.price_revision_date:
            return self.revised_cost_for_two
        return self.cost_for_two


@dataclass(frozen=True)
class MenuItem:
    """A dish on a restaurant's menu with an optional price rise."""

    item_id: str
    restaurant_id: str
    item_name: str
    category: str
    is_veg: bool
    base_price: int
    is_available: bool
    price_rise_date: date | None = None
    risen_price: int | None = None

    def price_on(self, day: date) -> int:
        """Menu price in effect on the given day."""
        if self.price_rise_date is not None and day >= self.price_rise_date:
            return self.risen_price
        return self.base_price


@dataclass(frozen=True)
class DeliveryPartner:
    """A delivery rider operating in one city."""

    partner_id: str
    name: str
    phone: str
    vehicle_type: str
    city: City
    rating: float
    status: str
    joined_date: date


@dataclass(frozen=True)
class Platform:
    """The complete generated platform: every entity across the whole simulation."""

    customers: tuple[Customer, ...]
    restaurants: tuple[Restaurant, ...]
    menu_items: tuple[MenuItem, ...]
    partners: tuple[DeliveryPartner, ...]
    menus_by_restaurant: dict[str, tuple[MenuItem, ...]] = field(compare=False)


# ---------------------------------------------------------------------------
# Building the platform
# ---------------------------------------------------------------------------
def _random_date(rng: random.Random, start: date, end: date) -> date:
    return start + timedelta(days=rng.randint(0, (end - start).days))


def _phone(rng: random.Random) -> str:
    return f"+91-{rng.randint(6_000_000_000, 9_999_999_999)}"


def _pincode(rng: random.Random, city: City) -> str:
    return f"{city.pincode_prefix}{rng.randint(1, 99):03d}"


def _round_to_5(value: float) -> int:
    return max(5, int(round(value / 5.0)) * 5)


def _build_customers(rng: random.Random, fake: Faker) -> list[Customer]:
    drafts = []
    for n in range(FOUNDING_CUSTOMERS + NEW_CUSTOMERS):
        if n < FOUNDING_CUSTOMERS:
            signup = _random_date(rng, FOUNDING_YEAR_START, FOUNDING_YEAR_END)
        else:
            signup = _random_date(rng, CALENDAR_START, CALENDAR_END)
        city = rng.choice(CITIES)
        first, last = fake.first_name(), fake.last_name()
        relocation = None
        if rng.random() < 0.06:
            earliest = max(signup, CALENDAR_START) + timedelta(days=30)
            if earliest < CALENDAR_END:
                new_city = rng.choice([c for c in CITIES if c != city])
                relocation = (_random_date(rng, earliest, CALENDAR_END), new_city, _pincode(rng, new_city))
        drafts.append({
            "first_name": first,
            "last_name": last,
            "phone": "" if rng.random() < ENTITY_DEFECT_RATE else _phone(rng),
            "pincode": "INVALID_PIN" if rng.random() < ENTITY_DEFECT_RATE else _pincode(rng, city),
            "signup": signup,
            "city": city,
            "weight": rng.lognormvariate(0.0, 1.0),  # heavy tail -> some very frequent customers
            "relocation": relocation,
        })

    # IDs follow signup order, like a real sequence
    drafts.sort(key=lambda d: (d["signup"], d["last_name"], d["first_name"]))
    customers = []
    for n, d in enumerate(drafts, start=1):
        handle = ".".join(re.sub(r"[^a-z]", "", part.lower()) for part in (d["first_name"], d["last_name"]))
        relocation_date, relocation_city, relocation_pincode = d["relocation"] or (None, None, None)
        customers.append(Customer(
            customer_id=f"CUST_{n:05d}",
            first_name=d["first_name"],
            last_name=d["last_name"],
            email=f"{handle}{n}@example.in",
            phone=d["phone"],
            signup_date=d["signup"],
            home_city=d["city"],
            home_pincode=d["pincode"],
            order_weight=d["weight"],
            relocation_date=relocation_date,
            relocation_city=relocation_city,
            relocation_pincode=relocation_pincode,
        ))
    return customers


def _build_restaurants(rng: random.Random, fake: Faker) -> list[Restaurant]:
    restaurants = []
    cuisines = list(CUISINE_MENUS)
    # Two always-listed restaurants carry a negative cost_for_two (loaded as NULL after cleansing)
    negative_cost_ids = set(rng.sample(range(1, FOUNDING_RESTAURANTS + 1), k=2))
    for n in range(1, FOUNDING_RESTAURANTS + NEW_RESTAURANTS + 1):
        founding = n <= FOUNDING_RESTAURANTS
        # Founding restaurants are spread round-robin so every city can always take orders
        city = CITIES[(n - 1) % len(CITIES)] if founding else rng.choice(CITIES)
        onboarded = (_random_date(rng, FOUNDING_YEAR_START, FOUNDING_YEAR_END) if founding
                     else _random_date(rng, CALENDAR_START, CALENDAR_END - timedelta(days=60)))
        cuisine = rng.choice(cuisines)
        area = rng.choice(city.areas)
        name = rng.choice(RESTAURANT_NAME_TEMPLATES).format(surname=fake.last_name(), cuisine=cuisine, area=area)
        cost = rng.choice((300, 400, 500, 700, 900, 1200, 1500))

        revision_date = revised_cost = offboarded = None
        if n in negative_cost_ids:
            cost = -150
        elif rng.random() < 0.20:
            revision_date = _random_date(rng, max(onboarded, CALENDAR_START) + timedelta(days=60), CALENDAR_END)
            revised_cost = max(200, cost + rng.choice((-100, 100, 200)))
        if not founding and rng.random() < 0.15:
            offboarded = _random_date(rng, onboarded + timedelta(days=90), CALENDAR_END + timedelta(days=365))

        restaurants.append(Restaurant(
            restaurant_id=f"REST_{n:03d}",
            name=name,
            cuisine=cuisine,
            city=city,
            area=area,
            rating=round(rng.uniform(3.4, 4.8), 1),
            cost_for_two=cost,
            onboarded_date=onboarded,
            popularity=rng.lognormvariate(0.0, 0.6),
            price_revision_date=revision_date,
            revised_cost_for_two=revised_cost,
            offboarded_date=offboarded,
        ))
    return restaurants


def _build_menu_items(rng: random.Random, restaurants: list[Restaurant]) -> list[MenuItem]:
    items = []
    for restaurant in restaurants:
        for item_name, category, is_veg, base_price in CUISINE_MENUS[restaurant.cuisine]:
            price = _round_to_5(base_price * rng.uniform(0.9, 1.15))
            rise_date = risen = None
            if rng.random() < 0.10:
                rise_date = _random_date(rng, max(restaurant.onboarded_date, CALENDAR_START) + timedelta(days=30), CALENDAR_END)
                risen = _round_to_5(price * rng.uniform(1.05, 1.12))
            items.append(MenuItem(
                item_id=f"ITEM_{len(items) + 1:05d}",
                restaurant_id=restaurant.restaurant_id,
                item_name=item_name,
                category=category,
                is_veg=is_veg,
                base_price=price,
                is_available=rng.random() > 0.05,
                price_rise_date=rise_date,
                risen_price=risen,
            ))
    return items


def _build_partners(rng: random.Random, fake: Faker) -> list[DeliveryPartner]:
    partners = []
    for n in range(1, FOUNDING_PARTNERS + NEW_PARTNERS + 1):
        founding = n <= FOUNDING_PARTNERS
        rating = round(rng.uniform(3.6, 5.0), 1)
        if rng.random() < ENTITY_DEFECT_RATE * 2:
            rating = 6.5  # dirty: out-of-range rating, loaded as NULL after cleansing
        partners.append(DeliveryPartner(
            partner_id=f"PART_{n:03d}",
            name=f"{fake.first_name()} {fake.last_name()}",
            phone=_phone(rng),
            vehicle_type=rng.choice(VEHICLE_TYPES),
            city=CITIES[(n - 1) % len(CITIES)] if founding else rng.choice(CITIES),
            rating=rating,
            status="ACTIVE" if founding else rng.choices(("ACTIVE", "ON_LEAVE", "INACTIVE"), (85, 10, 5))[0],
            joined_date=(_random_date(rng, FOUNDING_YEAR_START, FOUNDING_YEAR_END) if founding
                         else _random_date(rng, CALENDAR_START, CALENDAR_END)),
        ))
    return partners


@lru_cache(maxsize=1)
def build_platform() -> Platform:
    """Generate the whole platform from SEED (cached; identical on every call)."""
    rng = random.Random(SEED)
    fake = Faker("en_IN")
    fake.seed_instance(SEED)

    customers = _build_customers(rng, fake)
    restaurants = _build_restaurants(rng, fake)
    menu_items = _build_menu_items(rng, restaurants)
    partners = _build_partners(rng, fake)

    menus: dict[str, list[MenuItem]] = {}
    for item in menu_items:
        menus.setdefault(item.restaurant_id, []).append(item)

    return Platform(
        customers=tuple(customers),
        restaurants=tuple(restaurants),
        menu_items=tuple(menu_items),
        partners=tuple(partners),
        menus_by_restaurant={rid: tuple(items) for rid, items in menus.items()},
    )


# ---------------------------------------------------------------------------
# Daily snapshots
# ---------------------------------------------------------------------------
def _add_daily_noise(rows: list[dict[str, str]], rng: random.Random,
                     pad_fields: tuple[str, ...], case_fields: tuple[str, ...]) -> list[dict[str, str]]:
    """Apply cosmetic defects and duplicate rows that vary from day to day."""
    noisy = []
    for row in rows:
        row = dict(row)
        roll = rng.random()
        if roll < COSMETIC_DEFECT_RATE:
            column = rng.choice(pad_fields)
            row[column] = f"  {row[column]}   "
        elif roll < COSMETIC_DEFECT_RATE * 1.5 and case_fields:
            column = rng.choice(case_fields)
            row[column] = row[column].upper()
        noisy.append(row)
        if rng.random() < DUPLICATE_ROW_RATE:
            noisy.append(dict(row))
    return noisy


def snapshot_rows(platform: Platform, as_of: date) -> dict[str, list[dict[str, str]]]:
    """Master data rows as the source system would export them on `as_of`.

    Returns:
        Mapping of file name stem (e.g. "customers") to CSV rows.
    """
    def noise_rng(name: str) -> random.Random:
        return random.Random(f"{SEED}:{name}:{as_of.isoformat()}")

    customers = []
    for c in platform.customers:
        if c.signup_date > as_of:
            continue
        city, pincode = c.location_on(as_of)
        customers.append({
            "customer_id": c.customer_id, "customer_name": f"{c.first_name} {c.last_name}",
            "email": c.email, "phone": c.phone, "city": city.name, "state": city.state,
            "pincode": pincode, "signup_date": c.signup_date.isoformat(),
        })

    restaurants = [{
        "restaurant_id": r.restaurant_id, "name": r.name, "cuisine_type": r.cuisine,
        "city": r.city.name, "area": r.area, "rating": f"{r.rating:.1f}",
        "cost_for_two": str(r.cost_on(as_of)), "is_active_partner": "1" if r.is_active_on(as_of) else "0",
    } for r in platform.restaurants if r.is_listed_on(as_of)]

    listed = {r["restaurant_id"] for r in restaurants}
    menu_items = [{
        "item_id": m.item_id, "restaurant_id": m.restaurant_id, "item_name": m.item_name,
        "category": m.category, "is_veg": "1" if m.is_veg else "0",
        "base_price": f"{m.price_on(as_of):.2f}", "is_available": "1" if m.is_available else "0",
    } for m in platform.menu_items if m.restaurant_id in listed]

    partners = [{
        "partner_id": p.partner_id, "partner_name": p.name, "phone": p.phone,
        "vehicle_type": p.vehicle_type, "city": p.city.name, "rating": f"{p.rating:.1f}", "status": p.status,
    } for p in platform.partners if p.joined_date <= as_of]

    return {
        "customers": _add_daily_noise(customers, noise_rng("customers"),
                                      pad_fields=("customer_name", "city"), case_fields=("email",)),
        "restaurants": _add_daily_noise(restaurants, noise_rng("restaurants"),
                                        pad_fields=("name", "area"), case_fields=("cuisine_type",)),
        "menu_items": _add_daily_noise(menu_items, noise_rng("menu_items"),
                                       pad_fields=("item_name",), case_fields=("category",)),
        "delivery_partners": _add_daily_noise(partners, noise_rng("delivery_partners"),
                                              pad_fields=("partner_name",), case_fields=("vehicle_type",)),
        "payment_methods": [dict(pm) for pm in PAYMENT_METHODS],
    }


def write_master_csvs(as_of: date, output_dir: Path) -> list[Path]:
    """Write the `as_of` snapshot as `<name>_<YYYY-MM-DD>.csv` files.

    Each file is written to a temporary name and renamed into place, so the
    ingestion step never picks up a half-written file.
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    paths = []
    for name, rows in snapshot_rows(build_platform(), as_of).items():
        path = output_dir / f"{name}_{as_of.isoformat()}.csv"
        tmp_path = path.with_suffix(".csv.tmp")
        with open(tmp_path, "w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        os.replace(tmp_path, path)
        paths.append(path)
    return paths
