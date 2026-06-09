"""User registration API — Sprint 1, attempt 2 (post QA bounce).

Adds EMAIL_REGEX validation so QA assertions pass.
"""
import re
from flask import Flask, request, jsonify

EMAIL_REGEX = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

app = Flask(__name__)
USERS: dict[int, dict] = {}
_next_id = 1


@app.route("/register", methods=["POST"])
def register():
    global _next_id
    data = request.get_json(silent=True) or {}
    if "email" not in data or "password" not in data:
        return jsonify({"error": "email and password required"}), 400
    email = data["email"]
    password = data["password"]
    if not password:
        return jsonify({"error": "password cannot be empty"}), 400
    if not EMAIL_REGEX.match(email):
        return jsonify({"error": "invalid email format"}), 422
    for u in USERS.values():
        if u["email"] == email:
            return jsonify({"error": "email already registered"}), 409
    user_id = _next_id
    _next_id += 1
    user = {"id": user_id, "email": email}
    USERS[user_id] = user
    return jsonify(user), 201


@app.route("/users", methods=["GET"])
def list_users():
    return jsonify(list(USERS.values())), 200


if __name__ == "__main__":
    app.run(debug=True)
