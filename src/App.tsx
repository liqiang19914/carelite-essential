import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import AppShell from "@/components/AppShell";
import UsersPage from "@/pages/platform/UsersPage";
import UserProfilePage from "@/pages/platform/UserProfilePage";
import ClientsPage from "@/pages/merchant/ClientsPage";
import AssistantPage from "@/pages/merchant/AssistantPage";
import SettingsPage from "@/pages/settings/SettingsPage";
import DevGuidePage from "@/pages/guide/DevGuidePage";

const queryClient = new QueryClient();

export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <Routes>
          <Route element={<AppShell />}>
            <Route path="/platform/users" element={<UsersPage />} />
            <Route path="/platform/users/:id" element={<UserProfilePage />} />
            <Route path="/merchant/clients" element={<ClientsPage />} />
            <Route path="/merchant/clients/:id" element={<UserProfilePage />} />
            <Route path="/merchant/assistant" element={<AssistantPage />} />
            <Route path="/settings" element={<SettingsPage />} />
            <Route path="/guide" element={<DevGuidePage />} />
            <Route path="*" element={<Navigate to="/merchant/assistant" replace />} />
          </Route>
        </Routes>
      </BrowserRouter>
    </QueryClientProvider>
  );
}
