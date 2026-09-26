# Comfier user guide

Comfier lets you make images, video, audio and 3D models by describing what you want. The heavy lifting happens on
ComfyUI servers your admins have set up; you never need to touch a node graph.

- [Signing in](#signing-in)
- [Making things](#making-things)
- [Results](#results)
- [Shared](#shared)
- [Queue](#queue)
- [Settings](#settings)
- [For admins: backends](#for-admins-backends)
- [For admins: workflows](#for-admins-workflows)
- [How-to](#how-to)

## Signing in

Open Comfier and choose **Sign in with Authentik**. You'll go to your organization's Authentik login and come straight back. Your
account is created the first time you sign in. If you're in the admin group in Authentik, you'll see the admin
sections of Settings too.

The first time you sign in (or after an admin updates the privacy notice and asks everyone to agree again), you'll
see a short **Privacy notice**. Read it and choose **I agree** to continue. It explains that your prompts, reference
images and results are stored here, that admins can see them, and that anything you share is visible to other members.

## Making things

The **Image**, **Video**, **Audio** and **3D Model** pages all work the same way:

1. If there's more than one **Style**, pick one. Each style is a different ComfyUI workflow; its description says
   what it's good at.
2. Fill in **Describe what you want**.
3. Pick a **Shape** (square, landscape, portrait, wide or tall) where the style supports it.
4. Optionally open **More options**:
   - **Avoid**: things you don't want in the result, like "blurry, text".
   - **Seed**: leave blank for a random result each time, or enter a number to reproduce one.
5. Some styles also ask for a **Length** in seconds (video and audio), a **Reference image** / **Starting frame** /
   **Picture of the object**, **Quality**, **Prompt strength**, **How much to change the reference**, **Lyrics**, or
   **How many** outputs to make — only when that style's workflow uses them.
6. Choose **Generate**. If other jobs are waiting, you'll see roughly how long yours might take.

Your request appears under **Recent** straight away and updates by itself as it goes from queued to generating to
done. You can leave the page; the work carries on without you.

A page only shows the fields the chosen style uses. If a page says it has no workflow yet, an admin needs to add one.

## Results

**Results** shows everything you've made, newest first. Use the chips at the top to show one kind (Image, Video,
Audio, 3D Model) or only things that are still generating or that failed.

Each card shows the **style** that was used. Shared results have a small green share icon in the lower-right corner of the thumbnail.

Select a result to open it. From there you can:

- **Download** each output file.
- **Run again**: the same request with the same settings.
- **Tweak**: open the form pre-filled with this result's settings, so you can change something and generate again.
- **Delete** it, from the **⋯** menu.

If something failed, the result's page explains why, for example that no server was available or that ComfyUI
rejected the workflow.

On a finished result you can **Share with everyone** from the **⋯** menu. Choose whether to include the prompt
and/or reference image. Shared results appear under **Shared** for every signed-in member. Choose **Stop sharing**
to take yours back.

Image results also offer **Use as reference**, which opens the Image page with that output attached as your
reference image.

## Shared

**Shared** is a gallery of results members chose to make public. Filter by kind or **Only mine**. Open one to see
the output and, if the sharer included them, the prompt and reference. **Try this prompt** opens the studio
pre-filled when the prompt was shared.

## Queue

**Queue** shows every job waiting on or running on ComfyUI, with an estimate of when each will finish and when the
queue will clear. Your own jobs show your prompt; other people's don't (admins see all). The number beside **Queue**
in the navbar updates as jobs start and finish.

## Settings

**Your preferences** fill in the forms for you. You can still change them each time.

- **Default shape**: the shape selected when you open a page.
- **Always avoid**: pre-filled into **Avoid** under **More options**, for styles that support it.
- **Server**: only shown when there's more than one. Leave it on **Automatic (least busy)** unless you've been asked
  to use a particular one.

### Notifications

Comfier can tell you when something you made is ready, fails, or is cancelled, so you don't have to keep the page
open. Turn on either or both under **Settings → Notifications**:

- **Email**: sent to the email address on your sign-in account.
- **Slack**: a direct message from the Comfier bot, to the Slack account linked to your sign-in account.
- **Include the finished file**: attaches the result to the email or Slack message. Files too large to attach are
  left out, and the message links to the result instead.

You can't change the email address or Slack account here; they come from your sign-in account. If a switch is greyed
out, the note under it says why: the server may not have email or Slack set up, or your account may not be linked to
Slack yet. Once your admins link it, sign out and back in.

Notifications are off until you turn them on.

## For admins: backends

A backend is a ComfyUI server Comfier sends work to. Find them under **Settings → Backends**.

- **ComfyUI URL**: the address Comfier's server uses to reach ComfyUI, such as `http://gpu-box:8188`.
- **Auth token**: only needed if ComfyUI sits behind a proxy that expects a bearer token. It's stored encrypted.
  Leave the field blank when editing to keep the saved token, or tick **Remove saved token**.
- **Send new work to this backend**: turn it off to take a server out of rotation without deleting it.

Comfier checks a backend when you save it; choose **Test** in the list to check it again. With several enabled backends, each
new request goes to the reachable one with the shortest queue, unless the user picked a server in their settings.

## For admins: workflows

A workflow decides what one style on one page does. Find them under **Settings → Workflows**.

1. Build and test the workflow in ComfyUI.
2. Export it twice: **Workflow → Export (API)** for the workflow itself, and **Workflow → Export** if you want
   Comfier to pick up model download links from ComfyUI templates.
3. In Comfier, choose **Add workflow** (or open an existing one). At the top, upload one or both export files
   together, then either edit placeholders by hand or choose **Suggest placeholders** if LiteLLM is configured.
4. Replace the values users should control with placeholders (or let the assistant suggest them):

   | Placeholder | Becomes |
   |---|---|
   | `{{prompt}}` | Describe what you want |
   | `{{negative_prompt}}` | Avoid |
   | `{{seed}}` | Seed (random if left blank) |
   | `{{width}}`, `{{height}}` | The chosen shape at the workflow's base resolution |
   | `{{duration}}` | Length in seconds |
   | `{{frames}}` | Length × frame rate + 1 |
   | `{{image}}` | The uploaded starting image or picture of the object |

5. Pick the **Page** it belongs to, paste or upload the API JSON if you haven't already, and choose **Save**.
6. Set **Base resolution** to the size the model was trained at (for example 512 for SD 1.5, 1024 for SDXL), and
   **Frame rate** for video.
7. Leave **Offer this to users** ticked, and use **Order** to decide which style is listed first.

**Suggest placeholders** sends the API JSON to an LLM via LiteLLM (`LITELLM_URL`, `LITELLM_MODEL` and optionally
`LITELLM_API_KEY` in `.env`). Comfier shows what it changed and fills the JSON textarea for you to review; nothing
is saved until you choose **Save**. Edit the system prompt under **Settings → Workflow assistant**.

To remove a workflow, open it (or use the **⋯** menu on the list) and choose **Delete**. Past results stay; they just
lose the link back to this style.

**Settings → Needs attention** lists pages that have no workflow, backends that can't be reached, and workflows
whose models are missing from a backend.

### Models

Saving a workflow takes you to its page, which ends with **Models on your backends**: every model file the workflow
loads, and whether each backend has it. A green dot means installed; **Missing** means that backend doesn't have it;
**—** means that backend hasn't been checked yet. Comfier only sends a style's jobs to backends that have all of its
models, so a missing model never turns into a failed job.

Comfier finds the files from the workflow's loader nodes by itself. To let it install them, it also needs a download
link for each one. Either:

- type them into **Models**, one per line: the folder, a slash, the file name, a space and a direct link, like
  `vae/wan_2.1_vae.safetensors https://huggingface.co/…/wan_2.1_vae.safetensors`; or
- upload the regular export at the top of the workflow form (**Regular export**). Workflows based on ComfyUI's
  templates carry their download links in that file.

For Hugging Face, use the link to the file (`…/resolve/main/…`), not its web page (`…/blob/main/…`). Comfier fixes
`/blob/` links for you, and the downloader refuses anything that turns out to be a web page.

Then choose **Install N missing** under a backend. N counts only the files that backend can actually fetch. Progress
appears in the table as it happens; big models can take a while.

Anything that won't install is listed under the table in a **needs attention** box, with the reason and what to do:
a download that failed (for example a login is needed, or the link is wrong), a file with no link, or a file that
ComfyUI-Manager can't provide. A backend that only has Manager can install just the files in Manager's catalog, and
many workflows use files that aren't there; install the Comfier downloader node on it (see the README) to download
anything. Once you've fixed the cause, choose **Install** again to retry.

Choose **Re-check** after adding or removing model files on a server by hand, or after installing the downloader node.

## How-to

### How to reproduce a result exactly

1. Open the result from **Results**.
2. Choose **Run again**. The same seed and settings are used.

### How to make a variation of a result

1. Open the result and choose **Tweak**.
2. Change the prompt or shape, and clear **Seed** under **More options** if you want a different take.
3. Choose **Generate**.

### How to get a message when your work is done

1. Open **Settings**.
2. Under **Notifications**, turn on **Email**, **Slack**, or both.
3. Turn on **Include the finished file** if you want the result attached.
4. Choose **Save**.

### How to stop seeing the same unwanted things

1. Go to **Settings**.
2. Add them to **Always avoid**, separated by commas, and choose **Save**.

### How to take a ComfyUI server offline for maintenance (admins)

1. Go to **Settings → Backends** and open the server.
2. Untick **Send new work to this backend** and choose **Save**. Work already running on it finishes normally.

### How to add a ComfyUI template as a workflow (admins)

1. In ComfyUI, open the template from **Workflow → Browse Templates** and check it works.
2. Save it twice: **Workflow → Export (API)** for the workflow itself, and **Workflow → Export** for its download links.
3. In Comfier, add the workflow and upload both files at the top of the form. Use **Suggest placeholders** or add
   placeholders by hand, then choose **Save**.
4. On the workflow's page, choose **Install N missing** for each backend that needs the models.

### How to update the privacy notice (admins)

1. Go to **Settings → Privacy notice**.
2. Edit the text. Tick **Ask everyone to agree again** if the change is important enough that existing members
   should re-read it; leave it unticked for minor wording fixes.
3. Choose **Save**.

### How to check the job queue (admins)

Go to **Settings → Job queue** to open the Sidekiq dashboard, which shows jobs waiting, running and retrying.
