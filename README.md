# ITB – Information Toolbench

**ITB (Information Toolbench)** is a lightweight metadata modeling platform that abstracts development complexity through a powerful visual metalayer.  
It enables teams to design, manage, and extend metadata structures with clarity and precision — without diving into low-level code.

---

## ⚡ Quick Start

Get ITB running in minutes:

```bash
# 1. Copy environment file and adjust if needed
cp .env.example .env

# 2. Log in to Docker Hub for image access
docker login
# Request credentials: itb@banian.ch

# 3. Start ITB with Docker Compose
docker compose up -d
```

**Access ITB in your browser:**

- **WebApp:** [http://itb.localhost](http://itb.localhost)
- **API:** [http://api.itb.localhost](http://api.itb.localhost)  
- **Documentation:** [http://itb.localhost/docs](http://itb.localhost/docs)
- **Backend (PocketBase):** [http://itb.localhost/_](http://itb.localhost/_)

> **Default credentials:** admin@admin.com / admin12345

---

## 🚀 Key Features

- **Visual Metalayer**  
  Model metadata graphically to keep complexity under control and maintain a clean, abstracted development workflow.

- **Decoupled Architecture**  
  Full *decoupling of visual representation and objects* for cleaner, more maintainable solutions.

- **Modular Template System**  
  Extend functionality with reusable, customizable templates — ideal for evolving requirements.

- **Flexible & Extensible**  
  Easily adapt structures and logic as your data landscape grows.

---

## 📘 Documentation

Full documentation and guides are available here:

👉 **Website:** [https://itb.banian.ch](https://itb.banian.ch)  
👉 **Docs:** [https://itb.banian.ch/docs](https://itb.banian.ch/docs)

---

## 📦 Project Structure

```
/api          – Template Engine
/docs         – Documentation (Static)
/output       – Folder for generate metadata
  /json       - Metamodel Structure to import/export
  /templates  - Generate output by the template engine
```

---

## 📄 License

This project is released under a custom license.  
See the `LICENSE` file for details.
