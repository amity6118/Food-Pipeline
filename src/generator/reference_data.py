"""Static reference data for the simulated food-delivery platform."""

from dataclasses import dataclass

# One seed drives every generated value, so any date can be regenerated exactly.
SEED = 42


@dataclass(frozen=True)
class City:
    """An operating city with its pincode prefix and delivery areas."""

    name: str
    state: str
    pincode_prefix: str
    areas: tuple[str, ...]


CITIES: tuple[City, ...] = (
    City("Bengaluru", "Karnataka", "560", ("Indiranagar", "Koramangala", "HSR Layout", "Whitefield", "Jayanagar")),
    City("Mumbai", "Maharashtra", "400", ("Bandra West", "Andheri East", "Powai", "Colaba", "Lower Parel")),
    City("Delhi", "Delhi", "110", ("Connaught Place", "Hauz Khas", "Saket", "Karol Bagh", "Dwarka")),
    City("Hyderabad", "Telangana", "500", ("Gachibowli", "Hitec City", "Banjara Hills", "Jubilee Hills", "Madhapur")),
    City("Chennai", "Tamil Nadu", "600", ("T. Nagar", "Adyar", "Anna Nagar", "Velachery", "Nungambakkam")),
    City("Pune", "Maharashtra", "411", ("Kothrud", "Viman Nagar", "Koregaon Park", "Hinjawadi", "Baner")),
    City("Kolkata", "West Bengal", "700", ("Park Street", "Salt Lake", "New Town", "Ballygunge", "Alipore")),
)

# cuisine -> (item name, category, is_veg, base price in rupees)
CUISINE_MENUS: dict[str, tuple[tuple[str, str, bool, int], ...]] = {
    "North Indian": (
        ("Butter Chicken", "Curry", False, 360),
        ("Paneer Butter Masala", "Curry", True, 310),
        ("Dal Makhani", "Curry", True, 260),
        ("Garlic Naan", "Bread", True, 75),
        ("Tandoori Roti", "Bread", True, 40),
        ("Chicken Tikka", "Starter", False, 340),
    ),
    "South Indian": (
        ("Masala Dosa", "Dosa", True, 140),
        ("Ghee Podi Idli", "Tiffin", True, 120),
        ("Medu Vada (2 pcs)", "Tiffin", True, 95),
        ("Filter Coffee", "Beverage", True, 60),
        ("Onion Rava Dosa", "Dosa", True, 160),
        ("Chettinad Chicken", "Curry", False, 380),
    ),
    "Biryani": (
        ("Hyderabadi Chicken Dum Biryani", "Biryani", False, 340),
        ("Lucknowi Mutton Biryani", "Biryani", False, 480),
        ("Paneer Subz Biryani", "Biryani", True, 280),
        ("Mirchi Ka Salan", "Side", True, 90),
        ("Burani Raita", "Side", True, 70),
        ("Chicken 65", "Starter", False, 290),
    ),
    "Chinese": (
        ("Veg Hakka Noodles", "Noodles", True, 210),
        ("Chicken Fried Rice", "Rice", False, 240),
        ("Chilli Chicken Gravy", "Main", False, 320),
        ("Veg Manchurian Dry", "Starter", True, 250),
        ("Crispy Corn Salt & Pepper", "Starter", True, 220),
        ("Steamed Chicken Momos (6 pcs)", "Momos", False, 180),
    ),
    "Fast Food": (
        ("Classic Cheese Burger", "Burger", True, 160),
        ("Crispy Chicken Burger", "Burger", False, 210),
        ("Peri Peri Fries", "Snack", True, 120),
        ("Farmhouse Pizza (10 inch)", "Pizza", True, 380),
        ("BBQ Chicken Wings", "Appetizer", False, 270),
        ("Chocolate Milkshake", "Beverage", True, 150),
    ),
    "Desserts": (
        ("Gulab Jamun (2 pcs)", "Mithai", True, 90),
        ("Rasmalai (2 pcs)", "Mithai", True, 120),
        ("Chocolate Truffle Pastry", "Bakery", True, 140),
        ("Sizzling Brownie with Ice Cream", "Dessert", True, 190),
        ("Kulfi Falooda", "Ice Cream", True, 130),
    ),
}

RESTAURANT_NAME_TEMPLATES: tuple[str, ...] = (
    "{surname}'s Kitchen",
    "The {cuisine} House",
    "{area} {cuisine} Co.",
    "Hotel {surname}",
    "{surname} Bhojanalay",
    "Spice of {area}",
)

VEHICLE_TYPES: tuple[str, ...] = ("Bike", "Scooter", "EV Scooter", "Bicycle")

PAYMENT_METHODS: tuple[dict[str, str], ...] = (
    {"payment_method_id": "PM_UPI", "method_name": "UPI", "method_category": "UPI"},
    {"payment_method_id": "PM_CC", "method_name": "Credit Card", "method_category": "CARD"},
    {"payment_method_id": "PM_DC", "method_name": "Debit Card", "method_category": "CARD"},
    {"payment_method_id": "PM_NB", "method_name": "Net Banking", "method_category": "NETBANKING"},
    {"payment_method_id": "PM_COD", "method_name": "Cash on Delivery", "method_category": "COD"},
    {"payment_method_id": "PM_WALLET", "method_name": "Digital Wallet", "method_category": "WALLET"},
)
