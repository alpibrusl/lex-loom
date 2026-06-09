"""User registration API — Sprint 1, attempt 1.

Deliberately missing email format validation to trigger QA bounce.
"""
from flask import Flask, request, jsonify

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
    # ⚠ No email format check — any string accepted
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
