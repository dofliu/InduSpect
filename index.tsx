

import React, { useState, useCallback, useId, useEffect, useRef } from 'react';
import ReactDOM from 'react-dom/client';
import { GoogleGenAI, Type } from "@google/genai";

// --- Custom Hooks ---
const usePersistentState = <T,>(key: string, initialValue: T): [T, React.Dispatch<React.SetStateAction<T>>] => {
    const [state, setState] = useState<T>(() => {
        try {
            const storedValue = window.localStorage.getItem(key);
            return storedValue ? JSON.parse(storedValue) : initialValue;
        } catch (error) {
            console.error(`Error reading localStorage key “${key}”:`, error);
            return initialValue;
        }
    });

    useEffect(() => {
        try {
            window.localStorage.setItem(key, JSON.stringify(state));
        } catch (error) {
            console.error(`Error setting localStorage key “${key}”:`, error);
        }
    }, [key, state]);

    return [state, setState];
};


// --- Type Definitions ---
interface Point { x: number; y: number; }
interface Line { p1: Point; p2: Point; }
interface MeasurementLines {
    ref: Line | null;
    target: Line | null;
}
interface Dimension {
    object_name: string | null;
    value: number | null;
    unit: string | null;
}
interface AnalysisResult {
    equipment_type: string;
    readings: {
        label: string;
        value: number | null;
        unit: string | null;
    }[];
    condition_assessment: string;
    is_anomaly: boolean;
    summary: string;
    dimensions: Dimension | null;
    measurementLines?: MeasurementLines | null;
}

type ChecklistItemStatus = 'pending' | 'capturing' | 'captured' | 'loading' | 'success' | 'error' | 'confirmed';

interface ChecklistItem {
    id: string;
    task: string;
    dataUrl: string | null;
    mimeType: string | null;
    imageDimensions?: { width: number; height: number; } | null;
    status: ChecklistItemStatus;
    result: AnalysisResult | null;
    error: string | null;
}

type AppState = 'IDLE' | 'EXTRACTING' | 'CAPTURE' | 'ANALYZING' | 'REVIEW' | 'QUICK_ANALYSIS_CAPTURE' | 'QUICK_ANALYSIS_ANALYZING' | 'QUICK_ANALYSIS_REVIEW';
type ReportState = 'idle' | 'generating' | 'error';

// --- Helper Functions ---
const dataUrlToGenerativePart = (dataUrl: string, mimeType: string) => {
    const base64Data = dataUrl.split(',')[1];
    return {
        inlineData: { data: base64Data, mimeType: mimeType },
    };
};

const processImageFile = (file: File): Promise<{ dataUrl: string; dimensions: { width: number, height: number } }> => {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = (e_reader) => {
            const dataUrl = e_reader.target!.result as string;
            const img = new Image();
            img.onload = () => {
                resolve({
                    dataUrl,
                    dimensions: { width: img.naturalWidth, height: img.naturalHeight }
                });
            };
            img.onerror = (err) => reject(err);
            img.src = dataUrl;
        };
        reader.onerror = (err) => reject(err);
        reader.readAsDataURL(file);
    });
};

const fileToDataUrl = (file: File): Promise<string> => {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result as string);
        reader.onerror = reject;
        reader.readAsDataURL(file);
    });
};


// --- Child Components ---

const Stepper = ({ appState }: { appState: AppState }) => {
    const steps = [
        { id: 'IDLE', label: '上傳定檢表' },
        { id: 'CAPTURE', label: '拍攝巡檢照片' },
        { id: 'REVIEW', label: '分析與審核' },
    ];

    const getStateClassName = (stepId: string): string => {
        if (stepId === 'IDLE' && (appState === 'IDLE' || appState === 'EXTRACTING')) return 'step active';
        if (stepId === 'CAPTURE' && appState === 'CAPTURE') return 'step active';
        if (stepId === 'REVIEW' && (appState === 'REVIEW' || appState === 'ANALYZING')) return 'step active';

        if (steps.findIndex(s => s.id === appState) > steps.findIndex(s => s.id === stepId)) {
             return 'step completed';
        }
       
        return 'step';
    }
    
    if (appState.startsWith('QUICK_ANALYSIS')) {
        return null;
    }

    return (
        <div className="stepper" aria-label="進度">
            {steps.map(step => (
                <div key={step.id} className={getStateClassName(step.id)}>
                    {step.label}
                </div>
            ))}
        </div>
    );
};

const LoadingComponent = ({ text }: { text: string }) => (
    <div className="loading-container" role="status">
        <div className="loader"></div>
        <p>{text}</p>
    </div>
);

const ImageWithMeasurementOverlay: React.FC<{
    src: string;
    alt: string;
    lines?: MeasurementLines | null;
    dimensions?: { width: number, height: number } | null;
}> = ({ src, alt, lines, dimensions }) => {
    return (
        <div className="image-overlay-container">
            <img src={src} alt={alt} />
            {lines && dimensions && (
                <svg
                    className="measurement-overlay"
                    viewBox={`0 0 ${dimensions.width} ${dimensions.height}`}
                >
                    {lines.ref && (
                        <line
                            x1={lines.ref.p1.x} y1={lines.ref.p1.y}
                            x2={lines.ref.p2.x} y2={lines.ref.p2.y}
                            stroke="#42a5f5" strokeWidth="40" strokeOpacity="0.9"
                        />
                    )}
                    {lines.target && (
                        <line
                            x1={lines.target.p1.x} y1={lines.target.p1.y}
                            x2={lines.target.p2.x} y2={lines.target.p2.y}
                            stroke="#d32f2f" strokeWidth="40" strokeOpacity="0.9"
                        />
                    )}
                </svg>
            )}
        </div>
    );
};


const ImageMeasurementTool: React.FC<{
    imageUrl: string;
    onComplete: (dim: Dimension, lines: MeasurementLines) => void;
    onClose: () => void;
}> = ({ imageUrl, onComplete, onClose }) => {
    const canvasRef = useRef<HTMLCanvasElement>(null);
    const [stage, setStage] = useState<'draw_reference' | 'enter_reference' | 'draw_target' | 'done'>('draw_reference');
    const [lines, setLines] = useState<MeasurementLines>({ ref: null, target: null });
    const [startPoint, setStartPoint] = useState<Point | null>(null);
    const [mousePos, setMousePos] = useState<Point | null>(null);
    const [refLength, setRefLength] = useState<string>('85.6'); // Default to credit card width in mm
    const [refUnit, setRefUnit] = useState<string>('mm');

    const draw = useCallback(() => {
        const canvas = canvasRef.current;
        if (!canvas) return;
        const ctx = canvas.getContext('2d');
        if (!ctx) return;
        
        const img = new Image();
        img.src = imageUrl;
        img.onload = () => {
            canvas.width = img.width;
            canvas.height = img.height;
            ctx.drawImage(img, 0, 0);

            // Draw completed lines
            ctx.lineWidth = 5;
            if (lines.ref) {
                ctx.strokeStyle = '#42a5f5'; // Light Blue
                ctx.beginPath();
                ctx.moveTo(lines.ref.p1.x, lines.ref.p1.y);
                ctx.lineTo(lines.ref.p2.x, lines.ref.p2.y);
                ctx.stroke();
            }
            if (lines.target) {
                ctx.strokeStyle = '#d32f2f'; // Red
                ctx.beginPath();
                ctx.moveTo(lines.target.p1.x, lines.target.p1.y);
                ctx.lineTo(lines.target.p2.x, lines.target.p2.y);
                ctx.stroke();
            }

            // Draw currently drawing line
            if (startPoint && mousePos) {
                 ctx.strokeStyle = stage === 'draw_reference' ? '#42a5f5' : '#d32f2f';
                 ctx.beginPath();
                 ctx.moveTo(startPoint.x, startPoint.y);
                 ctx.lineTo(mousePos.x, mousePos.y);
                 ctx.stroke();
            }
        }
    }, [imageUrl, lines, startPoint, mousePos, stage]);

    useEffect(() => {
        draw();
    }, [draw]);

    const getCanvasCoords = (clientX: number, clientY: number): Point => {
        const canvas = canvasRef.current;
        if (!canvas) return { x: 0, y: 0 };
        const rect = canvas.getBoundingClientRect();
        const scaleX = canvas.width / rect.width;
        const scaleY = canvas.height / rect.height;
        return {
            x: (clientX - rect.left) * scaleX,
            y: (clientY - rect.top) * scaleY,
        };
    };

    const handleInteractionStart = (clientX: number, clientY: number) => {
        if (stage !== 'draw_reference' && stage !== 'draw_target') return;
        setStartPoint(getCanvasCoords(clientX, clientY));
    };

    const handleInteractionMove = (clientX: number, clientY: number) => {
        if (!startPoint) return;
        setMousePos(getCanvasCoords(clientX, clientY));
    };

    const handleInteractionEnd = (clientX: number, clientY: number) => {
        if (!startPoint) return;
        const endPoint = getCanvasCoords(clientX, clientY);
        if (stage === 'draw_reference') {
            setLines(prev => ({ ...prev, ref: { p1: startPoint, p2: endPoint } }));
            setStage('enter_reference');
        } else if (stage === 'draw_target') {
            setLines(prev => ({ ...prev, target: { p1: startPoint, p2: endPoint } }));
            setStage('done');
        }
        setStartPoint(null);
        setMousePos(null);
    };

    // Mouse Event Handlers
    const handleMouseDown = (e: React.MouseEvent<HTMLCanvasElement>) => handleInteractionStart(e.clientX, e.clientY);
    const handleMouseMove = (e: React.MouseEvent<HTMLCanvasElement>) => handleInteractionMove(e.clientX, e.clientY);
    const handleMouseUp = (e: React.MouseEvent<HTMLCanvasElement>) => handleInteractionEnd(e.clientX, e.clientY);

    // Touch Event Handlers
    const handleTouchStart = (e: React.TouchEvent<HTMLCanvasElement>) => {
        e.preventDefault();
        const touch = e.touches[0];
        handleInteractionStart(touch.clientX, touch.clientY);
    };
    const handleTouchMove = (e: React.TouchEvent<HTMLCanvasElement>) => {
        e.preventDefault();
        const touch = e.touches[0];
        handleInteractionMove(touch.clientX, touch.clientY);
    };
    const handleTouchEnd = (e: React.TouchEvent<HTMLCanvasElement>) => {
        e.preventDefault();
        const touch = e.changedTouches[0];
        handleInteractionEnd(touch.clientX, touch.clientY);
    };

    const calculateDistance = (p1: Point, p2: Point) => Math.sqrt(Math.pow(p2.x - p1.x, 2) + Math.pow(p2.y - p1.y, 2));

    const handleCalculation = () => {
        if (!lines.ref || !lines.target || !refLength) return;

        const refPixelLength = calculateDistance(lines.ref.p1, lines.ref.p2);
        const targetPixelLength = calculateDistance(lines.target.p1, lines.target.p2);
        const realRefLength = parseFloat(refLength);

        if (refPixelLength === 0 || isNaN(realRefLength)) return;

        const pixelsPerUnit = refPixelLength / realRefLength;
        const realTargetLength = targetPixelLength / pixelsPerUnit;

        onComplete({
            object_name: "手動測量裂縫",
            value: parseFloat(realTargetLength.toFixed(2)),
            unit: refUnit,
        }, lines);
    };

    const getInstruction = () => {
        switch (stage) {
            case 'draw_reference': return '步驟 1: 請在參考物 (如信用卡) 上拖曳畫線';
            case 'enter_reference': return '步驟 2: 輸入參考物的實際長度與單位';
            case 'draw_target': return '步驟 3: 在您要測量的物體上拖曳畫線';
            case 'done': return '步驟 4: 完成測量！';
            default: return '';
        }
    };
    
    const handleReset = () => {
        setLines({ ref: null, target: null });
        setStage('draw_reference');
    }

    return (
        <div className="measurement-modal-overlay">
            <div className="measurement-modal">
                <div className="measurement-header">
                    <h3>互動式尺寸測量工具</h3>
                    <button onClick={onClose} className="close-button">&times;</button>
                </div>
                <div className="measurement-instructions">{getInstruction()}</div>
                <div className="measurement-canvas-container">
                    <canvas 
                        ref={canvasRef}
                        onMouseDown={handleMouseDown}
                        onMouseMove={handleMouseMove}
                        onMouseUp={handleMouseUp}
                        onTouchStart={handleTouchStart}
                        onTouchMove={handleTouchMove}
                        onTouchEnd={handleTouchEnd}
                    />
                </div>
                <div className="measurement-controls">
                    {stage === 'enter_reference' && (
                        <div className="reference-input-group">
                            <input type="number" value={refLength} onChange={e => setRefLength(e.target.value)} placeholder="長度" />
                            <input type="text" value={refUnit} onChange={e => setRefUnit(e.target.value)} placeholder="單位" />
                            <button onClick={() => setStage('draw_target')}>確認參考</button>
                        </div>
                    )}
                    {stage === 'done' && <button onClick={handleCalculation}>完成並儲存</button>}
                    <button onClick={handleReset} className="button-secondary">重設</button>
                </div>
            </div>
        </div>
    );
};


const InspectionCard: React.FC<{
    item: ChecklistItem,
    onConfirm?: (id: string) => void,
    onSave?: (id: string) => void,
    onRetry: (id: string, eventOrFile: React.ChangeEvent<HTMLInputElement> | File) => void,
    onUpdateResult: (id: string, result: AnalysisResult) => void,
    onReanalyze?: (id: string, supplementalPrompt: string) => void,
    isQuickMode?: boolean,
}> = ({ item, onConfirm, onSave, onRetry, onUpdateResult, onReanalyze, isQuickMode = false }) => {
    const [isMeasuring, setIsMeasuring] = useState(false);
    const [supplementalPrompt, setSupplementalPrompt] = useState('');

    const handleResultChange = <K extends keyof AnalysisResult>(field: K, value: AnalysisResult[K]) => {
        if (!item.result) return;
        onUpdateResult(item.id, { ...item.result, [field]: value });
    };

    const handleReadingChange = (index: number, field: 'label' | 'value' | 'unit', value: string | number | null) => {
        if (!item.result || !item.result.readings) return;
        const newReadings = [...item.result.readings];
        newReadings[index] = { ...newReadings[index], [field]: value };
        handleResultChange('readings', newReadings);
    };

    const handleDimensionChange = (field: keyof Dimension, value: string | number | null) => {
         if (!item.result) return;
         const newDimension = { ...(item.result.dimensions || { object_name: '', value: null, unit: '' }), [field]: value };
         handleResultChange('dimensions', newDimension);
    }
    
    const handleMeasurementComplete = (dim: Dimension, lines: MeasurementLines) => {
        if (!item.result) return;
        const newResult = { ...item.result, dimensions: dim, measurementLines: lines };
        onUpdateResult(item.id, newResult);
        setIsMeasuring(false);
    }

    const renderEditableResult = (result: AnalysisResult) => (
        <div className="results-container editable">
            <div className="result-item">
                <label htmlFor={`equipment-type-${item.id}`}>設備類型</label>
                <input
                    type="text"
                    id={`equipment-type-${item.id}`}
                    value={result.equipment_type}
                    onChange={(e) => handleResultChange('equipment_type', e.target.value)}
                />
            </div>
             <div className="result-item">
                <label>儀表讀數</label>
                {result.readings && result.readings.length > 0 ? (
                    <div className="readings-grid editable">
                        {result.readings.map((reading, index) => (
                            <div key={index} className="reading-inputs">
                                <input type="text" aria-label="Reading Label" placeholder="標籤" value={reading.label} onChange={(e) => handleReadingChange(index, 'label', e.target.value)} />
                                <input type="number" aria-label="Reading Value" placeholder="數值" value={reading.value ?? ''} onChange={(e) => handleReadingChange(index, 'value', e.target.value === '' ? null : parseFloat(e.target.value))} />
                                <input type="text" aria-label="Reading Unit" placeholder="單位" value={reading.unit ?? ''} onChange={(e) => handleReadingChange(index, 'unit', e.target.value)} />
                            </div>
                        ))}
                    </div>
                ) : ( <span>無</span> )}
            </div>
            <div className="result-item">
                <label>測量尺寸 (AI 或手動)</label>
                 <div className="dimension-inputs">
                    <input type="text" aria-label="Dimension Object" placeholder="測量目標" value={result.dimensions?.object_name ?? ''} onChange={e => handleDimensionChange('object_name', e.target.value)} />
                    <input type="number" aria-label="Dimension Value" placeholder="數值" value={result.dimensions?.value ?? ''} onChange={e => handleDimensionChange('value', e.target.value === '' ? null : parseFloat(e.target.value))} />
                    <input type="text" aria-label="Dimension Unit" placeholder="單位" value={result.dimensions?.unit ?? ''} onChange={e => handleDimensionChange('unit', e.target.value)} />
                </div>
            </div>
            <div className="result-item">
                <label htmlFor={`condition-${item.id}`}>狀況評估</label>
                <textarea id={`condition-${item.id}`} value={result.condition_assessment} onChange={(e) => handleResultChange('condition_assessment', e.target.value)} rows={3} />
            </div>
            <div className="result-item anomaly-toggle">
                <label htmlFor={`anomaly-${item.id}`}>偵測到異常</label>
                <div className="toggle-switch">
                    <input type="checkbox" id={`anomaly-${item.id}`} checked={result.is_anomaly} onChange={(e) => handleResultChange('is_anomaly', e.target.checked)} />
                    <label htmlFor={`anomaly-${item.id}`}></label>
                </div>
                <span className={result.is_anomaly ? 'anomaly' : 'no-anomaly'}>{result.is_anomaly ? '是' : '否'}</span>
            </div>
            <div className="result-item summary">
                <label htmlFor={`summary-${item.id}`}>AI 總結</label>
                <textarea id={`summary-${item.id}`} value={result.summary} onChange={(e) => handleResultChange('summary', e.target.value)} rows={4} />
            </div>
            {onReanalyze && (
                <div className="reanalysis-section">
                    <label htmlFor={`reanalyze-prompt-${item.id}`}>補充提示或說明</label>
                    <textarea
                        id={`reanalyze-prompt-${item.id}`}
                        placeholder="例如：請專注於右下角的閥門，並忽略背景中的其他管道。"
                        value={supplementalPrompt}
                        onChange={(e) => setSupplementalPrompt(e.target.value)}
                        rows={3}
                    />
                    <button onClick={() => onReanalyze(item.id, supplementalPrompt)} className="button-secondary">
                        使用提示重新分析
                    </button>
                </div>
            )}
        </div>
    );
    
    const renderStaticResult = (result: AnalysisResult) => (
        <div className="results-container">
            <div className="result-item"><strong>設備類型：</strong><span>{result.equipment_type}</span></div>
            <div className="result-item">
                <strong>儀表讀數：</strong>
                {result.readings && result.readings.length > 0 ? (
                    <div className="readings-grid">
                        {result.readings.map((reading, index) => (
                            <div key={index} className="reading">
                                <span className="reading-label">{reading.label}:</span>
                                <span className="reading-value">{reading.value !== null && reading.value !== undefined ? `${reading.value} ${reading.unit || ''}`.trim() : 'N/A'}</span>
                            </div>
                        ))}
                    </div>
                ) : (<span>無</span>)}
            </div>
             <div className="result-item">
                <strong>測量尺寸：</strong>
                <span>{result.dimensions?.value ? `${result.dimensions.object_name}: ${result.dimensions.value} ${result.dimensions.unit}` : '無'}</span>
            </div>
            <div className="result-item"><strong>狀況評估：</strong><p>{result.condition_assessment}</p></div>
            <div className="result-item">
                <strong>偵測到異常：</strong>
                <span className={result.is_anomaly ? 'anomaly' : 'no-anomaly'}>{result.is_anomaly ? '是' : '否'}</span>
            </div>
             <div className="result-item summary"><strong>AI 總結：</strong><p>{result.summary}</p></div>
        </div>
    );
    
    return (
        <>
        {isMeasuring && item.dataUrl && <ImageMeasurementTool imageUrl={item.dataUrl} onComplete={handleMeasurementComplete} onClose={() => setIsMeasuring(false)} />}
        <div className={`inspection-card ${item.status === 'confirmed' ? 'confirmed' : ''}`} role="listitem">
           <h3 className="card-header">{item.task}</h3>
           <div className="card-content">
                <div className="image-container">
                    {item.dataUrl && (
                        <ImageWithMeasurementOverlay 
                            src={item.dataUrl}
                            alt={`預覽 ${item.task}`}
                            lines={item.result?.measurementLines}
                            dimensions={item.imageDimensions}
                        />
                    )}
                    {item.status === 'loading' && <div className="loader" role="status" aria-label="分析加載中"></div>}
                </div>
                <div style={{flex: '1 1 60%'}}>
                    {item.status === 'success' && item.result && renderEditableResult(item.result)}
                    {item.status === 'confirmed' && item.result && renderStaticResult(item.result)}
                    {item.status === 'error' && <div className="error-message" role="alert">{item.error}</div>}
                </div>
           </div>
            <div className="card-actions">
                {item.status === 'success' && (
                    <button onClick={() => setIsMeasuring(true)} className="button-secondary">手動測量尺寸</button>
                )}
                {item.status === 'error' && (
                    <>
                        <input type="file" id={`retry-upload-${item.id}`} accept="image/*" capture="environment" onChange={(e) => onRetry(item.id, e)} style={{ display: 'none' }} />
                        <label htmlFor={`retry-upload-${item.id}`} className="button-retry">重新拍攝並分析</label>
                    </>
                )}
                 {isQuickMode && onSave && item.status === 'success' && (
                    <button onClick={() => onSave(item.id)}>儲存此記錄</button>
                )}
                {!isQuickMode && onConfirm && (
                    <button onClick={() => onConfirm(item.id)} disabled={item.status !== 'success'}>
                        {item.status === 'confirmed' ? '已記錄' : '確認記錄'}
                    </button>
                )}
            </div>
        </div>
        </>
    );
};

const RecordsTable = ({ records }: { records: ChecklistItem[] }) => {
    if (records.length === 0) return null;
    return (
        <section className="records-section" aria-labelledby="records-heading">
            <h2 id="records-heading">檢測記錄</h2>
            <div className="records-table-container">
                <table className="records-table">
                    <thead>
                        <tr>
                            <th>#</th>
                            <th>檢測項目</th>
                            <th>照片</th>
                            <th>設備類型</th>
                            <th>儀表讀數</th>
                            <th>測量尺寸</th>
                            <th>AI 總結</th>
                            <th>異常?</th>
                        </tr>
                    </thead>
                    <tbody>
                        {records.map((record, index) => (
                            <tr key={record.id}>
                                <td>{index + 1}</td>
                                <td>{record.task}</td>
                                <td>
                                    {record.dataUrl && (
                                        <ImageWithMeasurementOverlay
                                            src={record.dataUrl}
                                            alt={record.task}
                                            lines={record.result?.measurementLines}
                                            dimensions={record.imageDimensions}
                                        />
                                    )}
                                </td>
                                <td>{record.result?.equipment_type}</td>
                                <td>{record.result?.readings.map(r => `${r.label}: ${r.value ?? 'N/A'} ${r.unit ?? ''}`).join(', ') || 'N/A'}</td>
                                <td>{record.result?.dimensions?.value ? `${record.result.dimensions.object_name}: ${record.result.dimensions.value} ${record.result.dimensions.unit}` : 'N/A'}</td>
                                <td>{record.result?.summary}</td>
                                <td>
                                    <span className={record.result?.is_anomaly ? 'anomaly' : 'no-anomaly'}>{record.result?.is_anomaly ? '是' : '否'}</span>
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            </div>
        </section>
    );
};

const ReportSection = ({
    records,
    report,
    reportState,
    reportError,
    onGenerate,
}: {
    records: ChecklistItem[];
    report: string | null;
    reportState: ReportState;
    reportError: string | null;
    onGenerate: () => void;
}) => {
    if (records.length === 0) {
        return null;
    }

    return (
        <section className="report-section" aria-labelledby="report-heading">
            <h2 id="report-heading">巡檢總結報告</h2>
            <div className="actions-bar">
                 <button onClick={onGenerate} disabled={reportState === 'generating'} className="button-generate-report">
                    {reportState === 'generating' ? '報告生成中...' : '產生總結報告'}
                </button>
            </div>
           
            {reportState === 'generating' && <LoadingComponent text="正在分析所有記錄並生成報告..." />}
            {reportState === 'error' && <div className="error-message" role="alert">{reportError}</div>}
            {report && (
                <div className="report-content">
                    <pre>{report}</pre>
                </div>
            )}
        </section>
    );
};


// --- Main App Component ---

const App = () => {
    const [appState, setAppState] = usePersistentState<AppState>('appState', 'IDLE');
    const [checklist, setChecklist] = usePersistentState<ChecklistItem[]>('checklist', []);
    const [confirmedRecords, setConfirmedRecords] = usePersistentState<ChecklistItem[]>('confirmedRecords', []);
    const [quickAnalysisItem, setQuickAnalysisItem] = useState<ChecklistItem | null>(null);
    const [error, setError] = useState<string | null>(null);
    const [report, setReport] = usePersistentState<string | null>('report', null);
    const [reportState, setReportState] = usePersistentState<ReportState>('reportState', 'idle');
    const [reportError, setReportError] = useState<string | null>(null);
    const [isOnline, setIsOnline] = useState(navigator.onLine);
    const uniqueId = useId();

    useEffect(() => {
        // On initial load, reset any states that shouldn't persist across sessions.
        
        // 1. Reset 'QUICK_ANALYSIS' app states because the photo data isn't persisted.
        const storedStateJSON = window.localStorage.getItem('appState');
        if (storedStateJSON) {
            try {
                const lastState = JSON.parse(storedStateJSON);
                if (typeof lastState === 'string' && lastState.startsWith('QUICK_ANALYSIS')) {
                    setAppState('IDLE');
                }
            } catch (e) {
                console.error("Error parsing persisted app state:", e);
                setAppState('IDLE');
            }
        }
        
        // 2. Reset report generation state if it was stuck on 'generating' from a previous session.
        const storedReportStateJSON = window.localStorage.getItem('reportState');
        if (storedReportStateJSON) {
            try {
                const lastReportState = JSON.parse(storedReportStateJSON);
                if (lastReportState === 'generating') {
                    setReportState('idle');
                }
            } catch (e) {
                console.error("Error parsing persisted report state:", e);
                setReportState('idle');
            }
        }
    }, []); // Run only once on component mount
    
    useEffect(() => {
        const handleOnline = () => setIsOnline(true);
        const handleOffline = () => setIsOnline(false);

        window.addEventListener('online', handleOnline);
        window.addEventListener('offline', handleOffline);

        return () => {
            window.removeEventListener('online', handleOnline);
            window.removeEventListener('offline', handleOffline);
        };
    }, []);

    const handleFormUpload = useCallback(async (event: React.ChangeEvent<HTMLInputElement>) => {
        const file = event.target.files?.[0];
        if (!file) return;

        setAppState('EXTRACTING');
        setError(null);

        try {
            const ai = new GoogleGenAI({ apiKey: process.env.API_KEY });
            const imagePart = dataUrlToGenerativePart(await fileToDataUrl(file), file.type);

            const prompt = `您是一位文件分析專家。請仔細閱讀提供的巡檢表單圖片，並提取出所有需要執行的巡檢項目。
            
            任務指令：
            1. 識別並列出表單中的每一個獨立的檢查任務或項目。
            2. 忽略標題、日期、簽名欄位等非任務相關的文字。
            
            輸出格式：
            請務必以一個單一、最小化、不含 markdown 標記的 JSON 物件格式回傳。所有回傳的文字都必須使用繁體中文。JSON 結構必須是一個包含字串陣列的物件，如下：
            { "tasks": ["項目一", "項目二", "項目三"] }`;

            const responseSchema = {
                type: Type.OBJECT,
                properties: {
                    tasks: {
                        type: Type.ARRAY,
                        items: { type: Type.STRING }
                    }
                },
                required: ["tasks"]
            };
            
            const response = await ai.models.generateContent({
                model: 'gemini-2.5-flash',
                contents: { parts: [imagePart, { text: prompt }] },
                config: {
                    responseMimeType: "application/json",
                    responseSchema: responseSchema,
                },
            });
            
            const resultJson = JSON.parse(response.text);
            const newChecklist: ChecklistItem[] = resultJson.tasks.map((task: string, index: number) => ({
                id: `${uniqueId}-${Date.now()}-${index}`,
                task,
                dataUrl: null,
                mimeType: null,
                imageDimensions: null,
                status: 'pending',
                result: null,
                error: null,
            }));

            if(newChecklist.length === 0) {
                throw new Error("無法從文件中提取任何檢查項目。");
            }

            setChecklist(newChecklist);
            setConfirmedRecords([]);
            setReport(null);
            setReportState('idle');
            setQuickAnalysisItem(null);
            setAppState('CAPTURE');

        } catch (e) {
            console.error(e);
            const errorMessage = e instanceof Error ? e.message : '發生未知錯誤。';
            setError(`無法處理您的定檢表：${errorMessage} 請檢查您的網路連線、API 金鑰或圖片內容後再試一次。`);
            setAppState('IDLE');
        }
    }, [uniqueId, setAppState, setChecklist, setConfirmedRecords, setReport, setReportState]);
    
    const analyzeImage = useCallback(async (dataUrl: string, mimeType: string, supplementalPrompt?: string): Promise<AnalysisResult> => {
        const ai = new GoogleGenAI({ apiKey: process.env.API_KEY });
        const imagePart = dataUrlToGenerativePart(dataUrl, mimeType);

        const basePrompt = `您是一位專業的工業巡檢 AI，擅長從單張圖像中提取結構化數據。您的任務是準確、客觀地分析提供的設備巡檢點圖像。

任務指令 (逐步執行):
1.  **思維鏈第一步：場景描述。** 請先用一句話簡要描述圖像中的整體場景和主要物體。
2.  **識別設備類型:** 根據場景，識別圖像中的主要設備類型 (例如：泵、閥門、壓力錶、馬達、配電盤、管道)。
3.  **讀取儀表/計量器:**
    *   如果圖像中存在任何形式的儀表 (數位式或指針式) 或計量器，請執行 OCR 或空間推理來讀取其數值和單位。
    *   如果存在多個讀數，請將它們全部提取出來。
    *   如果無法讀取、不存在儀表，或儀表被遮擋，請為相應欄位回傳 null。
4.  **評估設備狀況:**
    *   仔細評估設備的整體狀況，重點描述任何可見的磨損、生鏽、腐蝕、洩漏、物理損壞、裂縫或連接鬆脫的跡象。
    *   如果狀況良好，請明確註明「狀況良好」。
5.  **尋找參照物並測量尺寸:**
    *   檢查圖像中是否存在一張標準尺寸的信用卡 (寬度 85.6mm) 作為比例尺。
    *   如果找到信用卡，並且在「狀況評估」中發現了具體的物理特徵 (如裂縫)，請估算該特徵的長度 (單位為 mm)。
    *   如果沒有找到信用卡或沒有可測量的特徵，請為尺寸相關欄位回傳 null。
6.  **判斷異常:** 根據您的所有評估 (特別是狀況和讀數)，判斷是否存在需要關注的異常情況。
7.  **生成總結:** 用一句話總結您的所有發現。

${supplementalPrompt ? `使用者補充提示：\n${supplementalPrompt}\n請在分析時優先考慮此提示。` : ''}

輸出格式：
請務必將您的所有發現以一個單一、最小化、不含 markdown 標記的 JSON 物件格式回傳。所有回傳的文字都必須使用繁體中文。JSON 結構必須嚴格遵守以下格式：
`;
        const responseSchema = {
             type: Type.OBJECT,
                properties: {
                    equipment_type: { type: Type.STRING, description: "設備的類型" },
                    readings: {
                        type: Type.ARRAY,
                        description: "從儀表讀取的數值和單位列表",
                        items: {
                            type: Type.OBJECT,
                            properties: {
                                label: { type: Type.STRING, description: "讀數的標籤 (例如 '壓力', '溫度')" },
                                value: { type: Type.NUMBER, description: "讀取的數值，如果沒有則為 null" },
                                unit: { type: Type.STRING, description: "讀數的單位，如果沒有則為 null" }
                            },
                             required: ["label", "value", "unit"]
                        }
                    },
                    condition_assessment: { type: Type.STRING, description: "設備狀況的詳細評估" },
                    is_anomaly: { type: Type.BOOLEAN, description: "是否存在異常" },
                    summary: { type: Type.STRING, description: "一句話總結" },
                    dimensions: {
                        type: Type.OBJECT,
                        description: "基於參照物（如信用卡）測量的尺寸",
                        properties: {
                             object_name: { type: Type.STRING, description: "被測量物體的名稱 (例如 '裂縫')" },
                             value: { type: Type.NUMBER, description: "測量的長度數值，如果沒有則為 null" },
                             unit: { type: Type.STRING, description: "測量的單位 (例如 'mm')，如果沒有則為 null" }
                        },
                        required: ["object_name", "value", "unit"]
                    }
                },
                required: ["equipment_type", "readings", "condition_assessment", "is_anomaly", "summary", "dimensions"]
        };

        const response = await ai.models.generateContent({
            model: 'gemini-2.5-flash',
            contents: { parts: [imagePart, { text: basePrompt }] },
            config: {
                responseMimeType: "application/json",
                responseSchema: responseSchema,
            },
        });
        
        return JSON.parse(response.text);

    }, []);

    const handlePhotoCapture = useCallback(async (id: string, eventOrFile: React.ChangeEvent<HTMLInputElement> | File) => {
        const file = 'target' in eventOrFile ? (eventOrFile.target as HTMLInputElement).files?.[0] : eventOrFile;
        if (!file) return;

        const updateItemStatus = (itemId: string, status: ChecklistItemStatus, data: Partial<ChecklistItem> = {}) => {
            const updater = (prevList: ChecklistItem[]) => prevList.map(item =>
                item.id === itemId ? { ...item, status, ...data } : item
            );
            if(appState.startsWith('QUICK_ANALYSIS')) {
                setQuickAnalysisItem(prev => prev ? updater([prev])[0] : null);
            } else {
                setChecklist(updater);
            }
        };

        updateItemStatus(id, 'capturing');
        
        try {
            const { dataUrl, dimensions } = await processImageFile(file);
            updateItemStatus(id, 'captured', { dataUrl, mimeType: file.type, imageDimensions: dimensions });
        } catch (e) {
             console.error("Error processing image file:", e);
             const errorMessage = e instanceof Error ? e.message : '無法處理圖片檔案。';
             updateItemStatus(id, 'error', { error: errorMessage });
        }
    }, [appState, setChecklist]);

    const handleBatchAnalysis = useCallback(async () => {
        setAppState('ANALYZING');
        const itemsToAnalyze = checklist.filter(item => item.status === 'captured' && item.dataUrl);

        for (const item of itemsToAnalyze) {
            setChecklist(prev => prev.map(i => i.id === item.id ? { ...i, status: 'loading' } : i));
            try {
                const result = await analyzeImage(item.dataUrl!, item.mimeType!);
                setChecklist(prev => prev.map(i => i.id === item.id ? { ...i, status: 'success', result, error: null } : i));
            } catch (e) {
                console.error(`Error analyzing item ${item.id}:`, e);
                const errorMessage = e instanceof Error ? e.message : '發生未知分析錯誤。';
                setChecklist(prev => prev.map(i => i.id === item.id ? { ...i, status: 'error', error: errorMessage } : i));
            }
        }
        setAppState('REVIEW');
    }, [checklist, analyzeImage, setChecklist, setAppState]);
    
     const handleQuickAnalysis = useCallback(async (eventOrFile: React.ChangeEvent<HTMLInputElement> | File) => {
        const file = 'target' in eventOrFile ? (eventOrFile.target as HTMLInputElement).files?.[0] : eventOrFile;
        if (!file) return;

        const tempId = `${uniqueId}-quick-${Date.now()}`;
        const newItem: ChecklistItem = {
            id: tempId,
            task: `快速分析: ${file.name}`,
            dataUrl: null, mimeType: null, imageDimensions: null,
            status: 'capturing', result: null, error: null,
        };
        
        setQuickAnalysisItem(newItem);
        setAppState('QUICK_ANALYSIS_ANALYZING');
        
        try {
            const { dataUrl, dimensions } = await processImageFile(file);
            const updatedItem = { ...newItem, dataUrl, mimeType: file.type, imageDimensions: dimensions, status: 'loading' };
            setQuickAnalysisItem(updatedItem);

            const result = await analyzeImage(dataUrl, file.type);
            setQuickAnalysisItem({ ...updatedItem, status: 'success', result });
            setAppState('QUICK_ANALYSIS_REVIEW');

        } catch (e) {
            console.error("Error during quick analysis:", e);
            const errorMessage = e instanceof Error ? e.message : '發生未知錯誤。';
            setQuickAnalysisItem({ ...newItem, status: 'error', error: errorMessage });
            setAppState('QUICK_ANALYSIS_REVIEW');
        }
    }, [uniqueId, analyzeImage, setAppState]);

    const handleReanalyze = useCallback(async (id: string, supplementalPrompt: string) => {
        const itemToReanalyze = appState.startsWith('QUICK_ANALYSIS')
            ? quickAnalysisItem
            : checklist.find(item => item.id === id);

        if (!itemToReanalyze || !itemToReanalyze.dataUrl) return;

        const updateItemStatus = (status: ChecklistItemStatus, data: Partial<ChecklistItem> = {}) => {
            if (appState.startsWith('QUICK_ANALYSIS')) {
                setQuickAnalysisItem(prev => prev ? { ...prev, status, ...data } : null);
            } else {
                setChecklist(prev => prev.map(i => i.id === id ? { ...i, status, ...data } : i));
            }
        };

        updateItemStatus('loading', { error: null });

        try {
            const result = await analyzeImage(itemToReanalyze.dataUrl, itemToReanalyze.mimeType!, supplementalPrompt);
            updateItemStatus('success', { result });
        } catch (e) {
            console.error(`Error re-analyzing item ${id}:`, e);
            const errorMessage = e instanceof Error ? e.message : '發生未知再分析錯誤。';
            updateItemStatus('error', { error: errorMessage });
        }
    }, [appState, checklist, quickAnalysisItem, analyzeImage, setChecklist, setQuickAnalysisItem]);


    const handleUpdateResult = (id: string, newResult: AnalysisResult) => {
        if (appState.startsWith('QUICK_ANALYSIS')) {
             setQuickAnalysisItem(prev => (prev && prev.id === id ? { ...prev, result: newResult } : prev));
        } else {
            setChecklist(prev => prev.map(item => item.id === id ? { ...item, result: newResult } : item));
        }
    };
    
    const handleConfirmRecord = (id: string) => {
        const itemToConfirm = checklist.find(item => item.id === id);
        if (itemToConfirm && itemToConfirm.status === 'success') {
            setChecklist(prev => prev.map(item => item.id === id ? {...item, status: 'confirmed'} : item));
            setConfirmedRecords(prev => [...prev, itemToConfirm]);
        }
    };
    
    const handleSaveQuickRecord = (id: string) => {
        if (quickAnalysisItem && quickAnalysisItem.id === id && quickAnalysisItem.status === 'success') {
            setConfirmedRecords(prev => [...prev, quickAnalysisItem]);
            setQuickAnalysisItem(null); // Clear after saving
            setAppState('QUICK_ANALYSIS_CAPTURE'); // Ready for another quick analysis
        }
    }

    const handleConfirmAll = () => {
        const itemsToConfirm = checklist.filter(item => item.status === 'success');
        if (itemsToConfirm.length > 0) {
            setChecklist(prev => prev.map(item => item.status === 'success' ? {...item, status: 'confirmed'} : item));
            setConfirmedRecords(prev => [...prev, ...itemsToConfirm]);
        }
    };

    const handleGenerateReport = useCallback(async () => {
        if (confirmedRecords.length === 0) {
            setReportError("沒有可供生成報告的已確認記錄。");
            setReportState('error');
            return;
        }

        setReportState('generating');
        setReportError(null);
        setReport(null);

        try {
            const ai = new GoogleGenAI({ apiKey: process.env.API_KEY });
            const recordsData = confirmedRecords.map(r => ({
                task: r.task,
                ...r.result
            }));

            const prompt = `您是一位經驗豐富的工廠營運經理 AI 助理。

背景資料：
以下是一個 JSON 陣列，包含了某次設施巡檢中每個檢查點的數據。每個物件代表一個巡檢點的發現。
${JSON.stringify(recordsData, null, 2)}

任務指令：
請根據上述數據，生成一份不超過 300 字的高階主管級摘要報告。報告應包含以下三個部分，並使用 Markdown 格式化：
1.  **總體概述**: 簡要總結本次巡檢的整體情況，包括檢查了多少項目，以及發現異常的比例。
2.  **關鍵問題**: 以點列方式，列出所有被標記為 \`"is_anomaly": true\` 的項目。對於每個問題，明確指出設備位置 (task) 和具體問題 (condition\_assessment 或 summary)。如果沒有異常，請註明「本次巡檢未發現顯著異常」。
3.  **建議措施**: 根據發現的關鍵問題，提出 1-2 條具體的、可操作的後續建議 (例如：「建議維修團隊檢查泵 A-01 的生鏽情況」)。
4.  **結論**: 用一句話總結設施的整體維護狀況。

報告語氣應正式、專業且簡潔。直接輸出報告內容，不要包含任何額外的開場白或結語。`;

            const response = await ai.models.generateContent({
                model: 'gemini-2.5-pro',
                contents: prompt,
            });
            setReport(response.text);
            setReportState('idle');
        } catch (e) {
            console.error("Error generating report:", e);
            const errorMessage = e instanceof Error ? e.message : '發生未知錯誤。';
            setReportError(`報告生成失敗：${errorMessage}`);
            setReportState('error');
        }
    }, [confirmedRecords]);
    
    const startNewInspection = () => {
        // Clear all relevant state but keep confirmed records for viewing until a new checklist is uploaded
        setAppState('IDLE');
        setChecklist([]);
        setError(null);
        setReport(null);
        setReportState('idle');
        setReportError(null);
        setQuickAnalysisItem(null);
    };
    
    const resetAllData = () => {
         if (window.confirm("您確定要清除所有巡檢資料嗎？此操作無法復原。")) {
            window.localStorage.clear();
            // Reload the page to ensure all state is reset from scratch
            window.location.reload();
        }
    }
    
    const activeChecklistItems = checklist.filter(item => item.status !== 'confirmed');
    const allCaptured = checklist.length > 0 && checklist.every(item => item.dataUrl !== null || item.status === 'confirmed');
    const allAnalyzed = checklist.length > 0 && checklist.every(item => item.status === 'success' || item.status === 'error' || item.status === 'confirmed');
    const hasSuccessItems = checklist.some(item => item.status === 'success');
    const hasPendingItems = checklist.some(item => item.status === 'pending' || item.status === 'capturing' || item.status === 'captured');


    return (
        <>
        <div className="container">
            <header>
                <h1>InduSpect - AI 智慧巡檢原型</h1>
                <p>工業技術研究院 機械與系統研究所 智慧工廠系統整合技術組</p>
            </header>

            <Stepper appState={appState} />
            
            <main>
                {appState === 'IDLE' && (
                    <section className="upload-section">
                        <h2>步驟 1: 上傳您的定檢表</h2>
                         <p>請上傳一張包含所有巡檢項目的定檢表照片，AI 將自動為您建立數位檢查清單。</p>
                        <div className="actions-bar vertical">
                            <label htmlFor="form-upload" className="file-upload-label">選擇定檢表照片</label>
                            <input type="file" id="form-upload" accept="image/*" onChange={handleFormUpload} />
                             <div className="upload-section-divider">或</div>
                            <button onClick={() => setAppState('QUICK_ANALYSIS_CAPTURE')} className="button-secondary full-width">
                                試試單張照片快速分析
                            </button>
                        </div>
                        {error && <div className="error-message" role="alert">{error}</div>}
                    </section>
                )}
                
                {appState === 'EXTRACTING' && <LoadingComponent text="正在從您的定檢表中提取巡檢項目..." />}

                {appState === 'CAPTURE' && (
                    <section className="capture-section">
                        <h2>步驟 2: 拍攝巡檢照片</h2>
                        <p>請依照下方清單，依序為每個項目拍攝清晰的照片。您可以在離線狀態下完成所有拍攝。</p>
                        <ul className="checklist">
                            {checklist.map(item => (
                                <li key={item.id} className={`checklist-item ${item.status === 'captured' ? 'completed' : ''} ${!hasPendingItems && item.status !== 'captured' ? '' : (checklist.find(i => i.status === 'pending' || i.status === 'capturing')?.id === item.id ? 'active' : '')}`}>
                                    <span className="checklist-item-text">{item.task}</span>
                                    <div className="checklist-item-action">
                                        {item.dataUrl && <img src={item.dataUrl} alt={`預覽 ${item.task}`} />}
                                        <input type="file" id={`capture-${item.id}`} accept="image/*" capture="environment" onChange={(e) => handlePhotoCapture(item.id, e)} style={{ display: 'none' }} />
                                        <label htmlFor={`capture-${item.id}`} className="action-button">
                                            {item.dataUrl ? '重新拍攝' : '拍攝照片'}
                                        </label>
                                    </div>
                                </li>
                            ))}
                        </ul>
                        <div className="actions-bar">
                            {/* FIX: Removed redundant `appState === 'ANALYZING'` check.
                                This component only renders when `appState` is 'CAPTURE', so the check was always false. */}
                             <button onClick={handleBatchAnalysis} disabled={!allCaptured}>
                                開始分析所有項目
                            </button>
                        </div>
                    </section>
                )}
                
                {appState === 'QUICK_ANALYSIS_CAPTURE' && (
                    <section className="quick-analysis-section">
                        <h2>快速分析模式</h2>
                        <p>無需建立檢查清單，直接上傳單張照片進行即時分析。</p>
                         <div className="actions-bar vertical">
                             <label htmlFor="quick-upload-file" className="file-upload-label">從檔案上傳</label>
                             <input type="file" id="quick-upload-file" accept="image/*" onChange={handleQuickAnalysis} />
                             
                             <label htmlFor="quick-upload-camera" className="file-upload-label">立即拍攝</label>
                             <input type="file" id="quick-upload-camera" accept="image/*" capture="environment" onChange={handleQuickAnalysis} />

                            <div className="upload-section-divider"></div>
                             
                             <button onClick={startNewInspection} className="button-secondary full-width">返回主流程</button>
                         </div>
                    </section>
                )}
                
                {(appState === 'ANALYZING' || appState === 'QUICK_ANALYSIS_ANALYZING') && <LoadingComponent text="AI 分析中，請稍候..." />}

                {(appState === 'REVIEW' || appState === 'QUICK_ANALYSIS_REVIEW') && (
                    <section className="review-section">
                        <h2>步驟 3: 分析與審核結果</h2>
                        <p>AI 已完成分析。請審核以下結果，您可以在卡片中直接修改任何欄位，並確認記錄。</p>
                        
                        {appState === 'REVIEW' && hasSuccessItems && (
                            <div className="actions-bar">
                                <button onClick={handleConfirmAll}>一鍵記錄所有已完成項目</button>
                            </div>
                        )}

                        <div className="inspection-grid">
                           {appState === 'QUICK_ANALYSIS_REVIEW' && quickAnalysisItem && (
                                <InspectionCard 
                                    item={quickAnalysisItem} 
                                    onRetry={handleQuickAnalysis}
                                    onUpdateResult={handleUpdateResult}
                                    onSave={handleSaveQuickRecord}
                                    onReanalyze={handleReanalyze}
                                    isQuickMode={true}
                                />
                           )}
                           {appState === 'REVIEW' && activeChecklistItems.map(item => (
                               <InspectionCard 
                                    key={item.id} 
                                    item={item} 
                                    onConfirm={handleConfirmRecord}
                                    onRetry={handlePhotoCapture}
                                    onUpdateResult={handleUpdateResult}
                                    onReanalyze={handleReanalyze}
                               />
                           ))}
                        </div>
                    </section>
                )}

                <RecordsTable records={confirmedRecords} />
                
                <ReportSection 
                    records={confirmedRecords}
                    report={report}
                    reportState={reportState}
                    reportError={reportError}
                    onGenerate={handleGenerateReport}
                />
                
                 {(appState !== 'IDLE' || confirmedRecords.length > 0) && (
                    <section className="control-section">
                        <h2>系統控制</h2>
                        <div className="actions-bar">
                             <button onClick={startNewInspection} className="button-secondary">開始新的巡檢</button>
                             <button onClick={resetAllData} className="button-retry">清除所有資料並重設</button>
                        </div>
                    </section>
                 )}

            </main>
            
            <footer>
                <p>&copy; 2025 工業技術研究院 機械與系統研究所 智慧工廠系統整合技術組. All Rights Reserved.</p>
            </footer>

        </div>
        <div className={`status-indicator ${isOnline ? 'online' : 'offline'}`} role="status">
           {isOnline ? '● 線上' : '● 離線'}
        </div>
        </>
    );
};

const root = ReactDOM.createRoot(document.getElementById('root')!);
root.render(<App />);