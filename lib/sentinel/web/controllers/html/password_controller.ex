defmodule Sentinel.Controllers.Html.PasswordController do
  @moduledoc """
  Handles the password create and reset actions
  """
  use Phoenix.Controller
  use Guardian.Phoenix.Controller

  alias Sentinel.Changeset.PasswordResetter
  alias Sentinel.Config
  alias Sentinel.Mailer
  alias Sentinel.UserHelper
  alias Sentinel.Util

  plug Guardian.Plug.VerifyHeader when action in [:authenticated_update]
  plug Guardian.Plug.LoadResource when action in [:authenticated_update]

  def new(conn, _params, _headers \\ %{}, _session \\ %{}) do
    render(conn, Sentinel.PasswordView, "new.html", %{conn: conn})
  end

  def create(conn, %{"email" => email}, _headers \\ %{}, _session \\ %{}) do
    user = Config.repo.get_by(Config.user_model, email: email)

    if is_nil(user) do
      send_redirect_and_flash(conn)
    else
      auth = Config.repo.get_by(Sentinel.Ueberauth, user_id: user.id, provider: "identity")
      if is_nil(auth) do
        send_redirect_and_flash(conn)
      else
        {password_reset_token, changeset} = auth |> PasswordResetter.create_changeset

        case Config.repo.update(changeset) do
          {:ok, updated_auth} ->
            updated_auth
            |> Config.repo.preload([:user])
            |> Map.get(:user)
            |> Mailer.send_password_reset_email(password_reset_token)
            _ -> nil
        end

        send_redirect_and_flash(conn)
      end
    end
  end

  defp send_redirect_and_flash(conn) do
    conn
    |> put_flash(:info, "You'll receive an email with instructions about how to reset your password in a few minutes. ")
    |> redirect(to: "/")
  end

  @doc """
  Resets a users password if the provided token matches
  Params should be:
  {user_id: 1, password_reset_token: "abc123"}
  """
  def update(conn, params = %{"user_id" => user_id}, _headers \\ %{}, _session \\ %{}) do # FIXME could extract all of this here, and on json side into another module
    user = Config.repo.get(UserHelper.model, user_id)
    password_reset_params = Util.params_to_ueberauth_auth_struct(params)

    changeset =
      Sentinel.Ueberauth
      |> Config.repo.get_by!(user_id: user.id, provider: "identity")
      |> PasswordResetter.reset_changeset(password_reset_params)

    case Config.repo.update(changeset) do
      {:ok, _auth} ->
        conn
        |> Guardian.Plug.sign_in(user)
        |> put_flash(:info, "Successfully updated password")
        |> redirect(to: Config.router_helper.account_path(Config.endpoint, :edit))
      {:error, _changeset} ->
        conn
        |> put_status(422)
        |> put_flash(:error, "Unable to reset your password")
        |> redirect(to: Config.router_helper.password_path(Config.endpoint, :new))
    end
  end

  def authenticated_update(conn, %{"account" => params}, current_user, _session) do
    auth = Config.repo.get_by(Sentinel.Ueberauth, user_id: current_user.id, provider: "identity")
    {password_reset_token, changeset} = auth |> PasswordResetter.create_changeset
    updated_auth = Config.repo.update!(changeset)

    password_reset_params = Util.params_to_ueberauth_auth_struct(params, password_reset_token)

    changeset =
      updated_auth
      |> PasswordResetter.reset_changeset(password_reset_params)

    case Config.repo.update(changeset) do
      {:ok, _updated_auth} ->
        conn
        |> put_flash(:info, "Update successful")
        |> redirect(to: Config.router_helper.account_path(Config.endpoint, :edit))
      {:error, changeset} ->
        render(conn, Sentinel.AccountView, "edit.html", %{conn: conn, user: current_user, changeset: changeset})
    end
  end
end