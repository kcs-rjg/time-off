# Time Off tool: setting it up (stage 1)

This takes about 20 minutes. Menu names in Supabase and GitHub change from time to time, so if a label below does not quite match, look for the nearest equivalent.

There are three files:

- **schema.sql** builds the database: the tables, the security rules and the starting term dates and bank holidays.
- **index.html** is the app itself.
- **SETUP.md** is this guide.

## 1. Create the London project

If you have not done this already:

1. In Supabase, click **New project** and choose your organisation.
2. Name it **kings-apps** and save the database password somewhere safe.
3. For **Region**, choose **West EU (London)**.

## 2. Build the database

1. In the new project, open **SQL Editor** in the left-hand menu and click **New query**.
2. Open **schema.sql**, check that the last few lines have your name and email address, then copy the whole file into the editor.
3. Click **Run**. You should see "Success. No rows returned".

## 3. Let the app reach its section of the database

The time off tool lives in its own walled-off section, called **timeoff**. Supabase needs to be told the app may use it.

1. Go to **Project Settings**, then **Data API** (sometimes just **API**).
2. Find **Exposed schemas**, add **timeoff** to the list and click **Save**.

## 4. Put the app on GitHub Pages

1. In GitHub, create a new repository called **time-off**. It must be **Public** for free GitHub Pages. That is safe: the code contains only the "visitor pass" key, and the security rules protect the data.
2. Your project's address and publishable key are already filled in near the top of **index.html**, so there is nothing to edit.
3. Upload **index.html** to the repository (**Add file**, then **Upload files**, then **Commit changes**).
4. Go to the repository's **Settings**, then **Pages**. Under **Branch**, choose **main** and **/(root)**, then **Save**.
5. After a minute, the page shows your address, eg `https://yourname.github.io/time-off/`.

## 5. Tell Supabase where the app lives

Sign-in links need to send people back to the right address.

1. In Supabase, go to **Authentication**, then **URL Configuration**.
2. Set **Site URL** to your GitHub Pages address, eg `https://yourname.github.io/time-off/`.
3. Under **Redirect URLs**, add the same address, and click **Save**.
4. Under **Authentication**, then **Sign In / Providers**, check that **Confirm email** is on and **Allow anonymous sign-ins** is off. Both are the normal settings, and the app relies on them.

## 6. Sign in and add your team

1. Open your GitHub Pages address and sign in with **rjg@kcs.org.uk**. Use the link in the email.
2. You will land on your own page, with **Team** and **Settings** tabs at the top because you are the administrator.
3. Go to **Settings** and check the term dates and bank holidays.
4. Go to **Team** and click **Add a person** for each colleague. Add the approvers (eg Dave) first, so that you can tick them when you add the people they approve for. For each person:
   - choose their contract, and enter their leave days or extra hours for the year;
   - tick their **approvers** (all of them must approve), **line managers** (only these see sickness) and anyone **copied in**;
   - for Gina, tick **Can record sickness for colleagues**.
5. Anyone who only approves (eg Dave) can be added with 0 leave days.

## Important: who can sign in during stage 1

Supabase's built-in email only sends sign-in links to members of your Supabase account, and only a few times an hour. So in stage 1, **only you can sign in**. That is enough to set everything up and try it out, but colleagues cannot sign in yet.

Stage 2 connects a proper email-sending service. That opens sign-in to the team and turns on the notification emails. Every notification the app will send is already being queued in the database, so nothing is lost in the meantime.

## If something goes wrong

- **"Not set up yet" after signing in:** your email address in the database does not match the one you signed in with. Check the last lines of schema.sql.
- **An error mentioning "schema" or "timeoff":** step 3 has not been saved.
- **The sign-in link opens the wrong page:** check step 5.
