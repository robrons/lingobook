
import { prebuiltAppConfig } from "@mlc-ai/web-llm";
import * as fs from 'fs';

const models = prebuiltAppConfig.model_list
    .filter(m => !m.model_id.toLowerCase().includes('embed')) // Filter out embedding models
    .map(m => ({
        id: m.model_id,
        name: m.model_id, // Use ID as name for now, or try to make it prettier
        vram: m.vram_required_MB
    }));

fs.writeFileSync('available_models.json', JSON.stringify(models, null, 2));
console.log(`Saved ${models.length} models to available_models.json`);
